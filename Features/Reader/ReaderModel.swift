import SwiftUI
import SwiftData
import ImageIO

/// State of one open volume: the page groups, the position, the controls and progress saving.
///
/// In paged modes the reader scrolls through *groups*. A group is one page, or two
/// pages side by side (an iPad spread). In vertical mode it scrolls through pages.
@MainActor @Observable
final class ReaderModel {
    let volume: Volume
    let pageURLs: [URL]
    let cache: PageCache

    private(set) var mode: ReadingMode
    /// The page the user is on (0-based). In a spread, the higher page.
    private(set) var currentPage: Int
    private(set) var groups: [[Int]] = []
    /// Changes when `groups` are rebuilt, so the scroll view starts fresh.
    private(set) var layoutID = UUID()

    /// Scroll position in paged modes (index into `groups`).
    var groupPosition: Int?
    /// The page at the top of the screen in vertical mode.
    private(set) var verticalPosition: Int?
    /// Set when vertical mode must scroll to a page (slider, accessibility).
    private(set) var verticalScrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        let page: Int
        var animated = false
        let token = UUID()
    }

    var controlsVisible = true
    var showsModeMenu = false

    /// The "Two Pages" switch on iPad. Saved for all volumes.
    var prefersSpreads: Bool {
        didSet {
            UserDefaults.standard.set(prefersSpreads, forKey: Self.spreadsKey)
            rebuildGroups()
        }
    }

    /// True when the screen is wide enough for a spread (iPad in landscape).
    private(set) var spreadsAvailable = false
    private(set) var viewport: CGSize = .zero
    private var displayScale: CGFloat = 2
    private var visibleVerticalPages: Set<Int> = []
    /// Pixel size per page, read from the file headers (no decoding). nil = not known yet.
    private var pageSizes: [CGSize?]
    /// Pages that play as animations (GIF, APNG, WebP with more than one frame).
    private(set) var animatedPages: Set<Int> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The page to show after the scroll view is rebuilt. While it is set, position
    /// reports from the new scroll view (it starts at the top) are ignored.
    @ObservationIgnored private var pendingPage: Int?

    static let spreadsKey = "readerPrefersSpreads"

    init(volume: Volume) {
        self.volume = volume
        let urls = volume.pageFiles.indices.compactMap { volume.pageURL(at: $0) }
        pageURLs = urls
        cache = PageCache(urls: urls)
        pageSizes = Array(repeating: nil, count: urls.count)

        let defaultMode = UserDefaults.standard.string(forKey: SettingsKey.defaultReadingMode)
            .flatMap(ReadingMode.init(rawValue:)) ?? .rightToLeft
        mode = volume.series?.effectiveReadingMode(default: defaultMode) ?? defaultMode
        prefersSpreads = UserDefaults.standard.object(forKey: Self.spreadsKey) as? Bool ?? true
        currentPage = min(max(volume.currentPage, 0), max(urls.count - 1, 0))
        rebuildGroups()
        // markOpened() runs from ReaderView.onAppear, not here. SwiftUI can build a
        // ReaderView many times; a model change in init made the parent redraw and
        // build it again, in an endless loop.
    }

    var pageCount: Int { pageURLs.count }
    var isRightToLeft: Bool { mode == .rightToLeft }
    var usesSpreads: Bool { spreadsAvailable && prefersSpreads && mode != .vertical }

    /// Pages on screen now, in page order.
    var visiblePages: [Int] {
        if mode == .vertical { return [currentPage] }
        guard let g = groupPosition, groups.indices.contains(g) else { return [currentPage] }
        return groups[g]
    }

    /// "42 / 186", or "42–43 / 186" for a spread.
    func pageLabel(for pages: [Int]? = nil) -> String {
        let shown = (pages ?? visiblePages).map { $0 + 1 }
        let range = shown.count > 1 ? "\(shown.first!)–\(shown.last!)" : "\(shown.first ?? 1)"
        return "\(range) / \(pageCount)"
    }

    func aspectRatio(of page: Int) -> CGFloat {
        guard pageSizes.indices.contains(page), let size = pageSizes[page], size.height > 0 else { return 2.0 / 3.0 }
        return size.width / size.height
    }

    // MARK: Setup from the view

    /// Called when the view size changes (rotation, Split View) and on appear.
    func updateViewport(_ size: CGSize, scale: CGFloat, isRegularWidth: Bool) {
        guard size != viewport || scale != displayScale else { return }
        viewport = size
        displayScale = scale
        let available = isRegularWidth && size.width > size.height
        if available != spreadsAvailable {
            spreadsAvailable = available
            rebuildGroups()
        }
        prefetch()
    }

    /// Reads all page sizes from the file headers, and finds animated pages.
    /// Fast: no pixels are decoded.
    func loadPageSizes() async {
        let urls = pageURLs
        let (sizes, animated) = await Task.detached(priority: .userInitiated) {
            let sizes = urls.map(PageMetrics.pixelSize)
            let animated = Set(urls.indices.filter { PageMetrics.isAnimated(urls[$0], size: sizes[$0]) })
            return (sizes, animated)
        }.value
        pageSizes = sizes
        animatedPages = animated
        if shouldOpenAsWebtoon(sizes) { mode = .vertical }
        rebuildGroups()
    }

    /// Settings → Detect Webtoons: a series with no saved mode opens in Vertical Scroll
    /// when its pages are tall strips (median height at least 2.5 × the width).
    /// This is not saved, so a later change in Settings still applies.
    private func shouldOpenAsWebtoon(_ sizes: [CGSize?]) -> Bool {
        guard WebtoonDetector.isEnabled, mode != .vertical, volume.series?.readingMode == nil else { return false }
        let isTall = WebtoonDetector.isTallStrip(sizes)
        WebtoonDetector.remember(isTall, for: volume.id)
        return isTall
    }

    func isAnimated(_ page: Int) -> Bool { animatedPages.contains(page) }

    // MARK: Navigation

    enum TapZone { case left, center, right }

    func handleTap(_ zone: TapZone) {
        switch zone {
        case .center:
            withAnimation(.snappy(duration: 0.25)) { controlsVisible.toggle() }
        case .left:
            isRightToLeft ? next() : previous()
        case .right:
            isRightToLeft ? previous() : next()
        }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    private func step(by delta: Int) {
        if mode == .vertical {
            jump(toPage: currentPage + delta, animated: true)
            return
        }
        guard let g = groupPosition else { return }
        let target = g + delta
        guard groups.indices.contains(target) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            groupPosition = target
            controlsVisible = false
            showsModeMenu = false
        }
    }

    /// Slider: go straight to a page, without animation.
    func jump(toPage page: Int, animated: Bool = false) {
        let page = min(max(page, 0), max(pageCount - 1, 0))
        if mode == .vertical {
            verticalPosition = page
            verticalScrollRequest = ScrollRequest(page: page, animated: animated)
            didMove(to: page)
        } else if let g = groups.firstIndex(where: { $0.contains(page) }) {
            groupPosition = g
        }
    }

    /// The scroll target id after a rebuild: a group index (paged) or a page (vertical).
    /// Call once the new scroll view has appeared.
    /// `vertical` says which view asks. When the reader opens in a paged mode and then
    /// switches to Vertical Scroll (Detect Webtoons), the paged view must not take the
    /// target that belongs to the vertical view.
    func takeRestoreTarget(vertical: Bool) -> Int? {
        guard let page = pendingPage, vertical == (mode == .vertical) else { return nil }
        pendingPage = nil
        if mode == .vertical {
            verticalPosition = page
            return page
        }
        let group = groups.firstIndex { $0.contains(page) } ?? 0
        groupPosition = group
        return group
    }

    /// Called when the paged scroll view settles on a group.
    func groupPositionChanged() {
        guard pendingPage == nil, let g = groupPosition, groups.indices.contains(g) else { return }
        didMove(to: groups[g].last ?? 0)
    }

    /// Called when the vertical scroll view moves to another page.
    /// Called by the vertical reader when another page reaches the top of the screen.
    func verticalPageChanged(to page: Int) {
        guard pendingPage == nil else { return }
        verticalPosition = page
        didMove(to: page)
    }

    func setMode(_ newMode: ReadingMode) {
        showsModeMenu = false
        guard newMode != mode else { return }
        mode = newMode
        volume.series?.readingMode = newMode
        rebuildGroups()
        scheduleSave()
    }

    // MARK: Bookmarks

    var isCurrentPageBookmarked: Bool {
        visiblePages.contains { volume.bookmarkedPages.contains($0) }
    }

    func toggleBookmark() {
        if isCurrentPageBookmarked {
            volume.bookmarkedPages.removeAll { visiblePages.contains($0) }
        } else {
            volume.bookmarkedPages.append(currentPage)
            volume.bookmarkedPages.sort()
        }
        scheduleSave()
    }

    // MARK: Progress

    private func didMove(to page: Int) {
        guard page != currentPage else {
            prefetch()
            return
        }
        currentPage = page
        // The volume gets the page when the progress is saved, not on every page.
        // Each change to a model wakes the library views under the reader, and
        // with a large library their work makes scrolling stutter.
        if page == pageCount - 1, !volume.isFinished { volume.isFinished = true }
        prefetch()
        scheduleSave()
    }

    /// Call once, when the reader appears.
    func markOpened() {
        volume.lastReadAt = .now
        volume.series?.lastReadAt = .now
    }

    /// Saves one second after the last change, so fast page turns do not write every time.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Call on close and when the app goes to the background.
    func saveNow() {
        saveTask?.cancel()
        // lastReadAt was set on open. Setting it again here would reorder the
        // library under the reader on every save.
        if volume.currentPage != currentPage { volume.currentPage = currentPage }
        try? volume.modelContext?.save()
    }

    // MARK: Pages in memory

    /// Geometry can expose several short pages at once. Keep all of them ready.
    func verticalVisiblePagesChanged(_ pages: Set<Int>) {
        guard pages != visibleVerticalPages else { return }
        visibleVerticalPages = pages
        prefetch()
    }

    /// Current/visible pages first, then alternating neighbors in both directions.
    private func prefetch() {
        guard viewport.width > 0, pageCount > 0 else { return }
        var pages: [Int] = []
        if mode == .vertical {
            pages = [currentPage] + visibleVerticalPages.sorted()
            for distance in 1...4 {
                pages += [currentPage - distance, currentPage + distance]
            }
        } else if let g = groupPosition ?? groups.firstIndex(where: { $0.contains(currentPage) }) {
            for index in [g, g + 1, g - 1, g + 2, g - 2] where groups.indices.contains(index) {
                pages += groups[index]
            }
        }
        var seen = Set<Int>()
        let requests = pages.filter { pageURLs.indices.contains($0) && seen.insert($0).inserted }
            .map { page in
                let size = mode == .vertical ? verticalPixelSize(for: page)
                    : pagedPixelSize(for: page, in: groups.first { $0.contains(page) } ?? [page])
                return (page: page, size: size)
            }
        cache.update(requests)
    }

    /// The decode size so a page fills its slot on screen, and no bigger.
    private func pagedPixelSize(for page: Int, in group: [Int]) -> CGFloat {
        let slot = CGSize(width: viewport.width / CGFloat(max(group.count, 1)), height: viewport.height)
        let ratio = aspectRatio(of: page)
        let fitted = ratio > slot.width / slot.height
            ? CGSize(width: slot.width, height: slot.width / ratio)
            : CGSize(width: slot.height * ratio, height: slot.height)
        return max(fitted.width, fitted.height) * displayScale
    }

    /// Vertical mode fills the width. Very tall webtoon strips are capped at 8192 px.
    private func verticalPixelSize(for page: Int) -> CGFloat {
        let height = viewport.width / aspectRatio(of: page)
        return min(max(viewport.width, height) * displayScale, 8192)
    }

    private func rebuildGroups() {
        let page = currentPage
        visibleVerticalPages = []
        if usesSpreads {
            groups = PageMetrics.spreads(count: pageCount) { [pageSizes] index in
                guard let size = pageSizes[index] else { return false }
                return size.width > size.height
            }
        } else {
            groups = (0..<pageCount).map { [$0] }
        }
        groupPosition = groups.firstIndex { $0.contains(page) } ?? 0
        verticalPosition = page
        pendingPage = page
        layoutID = UUID()
        prefetch()
    }
}

// MARK: - Page cache

/// Downsampled active pages plus a bounded cache of recently viewed pages.
/// Every image goes through ImageDownsampler, at the size it is shown.
///
/// At most 2 pages decode at the same time, in the order they were asked for
/// (the current page first). A decode briefly needs the full-size bitmap
/// (about 35 MB for a 2400 × 3600 scan), so more at once only raises the peak.
@MainActor @Observable
final class PageCache {
    private(set) var images: [Int: UIImage] = [:]
    @ObservationIgnored private var loadedSize: [Int: CGFloat] = [:]
    @ObservationIgnored private var waiting: [(page: Int, size: CGFloat)] = []
    @ObservationIgnored private var running: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private let urls: [URL]
    @ObservationIgnored private let maxConcurrentDecodes = 2

    init(urls: [URL]) { self.urls = urls }

    @ObservationIgnored private var protectedPages: Set<Int> = []
    @ObservationIgnored private var recency: [Int: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0
    // The active window stays resident. Older pages share a bounded reuse budget.
    @ObservationIgnored private let reuseBudget = 96 * 1024 * 1024

    func update(_ requests: [(page: Int, size: CGFloat)]) {
        protectedPages = Set(requests.map(\.page))
        for (page, task) in running where !protectedPages.contains(page) {
            // Keep the slot occupied until the underlying decode finishes.
            task.cancel()
        }
        waiting = requests.filter { request in
            guard urls.indices.contains(request.page) else { return false }
            clock += 1
            recency[request.page] = clock
            return (loadedSize[request.page] ?? 0) < request.size * 0.9
        }
        trimRecentImages()
        startNext()
    }

    /// Release the reuse cache under memory pressure without blanking active pages.
    func discardRecentImages() {
        for page in Array(images.keys) where !protectedPages.contains(page) {
            images[page] = nil
            loadedSize[page] = nil
            recency[page] = nil
        }
    }

    private func trimRecentImages() {
        let recent = images.keys.filter { !protectedPages.contains($0) }
            .sorted { (recency[$0] ?? 0) > (recency[$1] ?? 0) }
        var bytes = 0
        for (index, page) in recent.enumerated() {
            let bitmap = images[page]?.cgImage
            bytes += (bitmap?.bytesPerRow ?? 0) * (bitmap?.height ?? 0)
            if bytes > reuseBudget || index >= 24 {
                images[page] = nil
                loadedSize[page] = nil
                recency[page] = nil
            }
        }
    }

    private func startNext() {
        while running.count < maxConcurrentDecodes,
              let next = waiting.firstIndex(where: { running[$0.page] == nil }) {
            let (page, size) = waiting.remove(at: next)
            let url = urls[page]
            running[page] = Task { [weak self] in
                let image = await ImageDownsampler.load(url, maxPixelSize: size)
                guard let self else { return }
                self.running[page] = nil
                if !Task.isCancelled, let image {
                    self.images[page] = image
                    self.loadedSize[page] = size
                    self.waiting.removeAll { $0.page == page && $0.size <= size / 0.9 }
                }
                self.trimRecentImages()
                self.startNext()
            }
        }
    }
}

// MARK: - Webtoon detection

/// Settings → Detect Webtoons: a series with no saved mode opens in Vertical Scroll
/// when its pages are tall strips (median height at least 2.5 × the width).
/// The result is not saved in the series, so a later change in Settings still applies.
/// It is cached per volume for this launch, so the series page and the library
/// show the same mode as the reader without reading the files again.
@MainActor
enum WebtoonDetector {
    private static var cache: [UUID: Bool] = [:]

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.detectWebtoons) as? Bool ?? true
    }

    nonisolated static func isTallStrip(_ sizes: [CGSize?]) -> Bool {
        let ratios = sizes.compactMap { size in size.flatMap { $0.width > 0 ? $0.height / $0.width : nil } }.sorted()
        guard !ratios.isEmpty else { return false }
        return ratios[ratios.count / 2] >= 2.5
    }

    static func remember(_ isTall: Bool, for volumeID: UUID) {
        cache[volumeID] = isTall
    }

    /// Reads the headers of up to 12 pages spread over the volume. Decodes nothing.
    static func isWebtoon(_ volume: Volume) async -> Bool {
        if let known = cache[volume.id] { return known }
        let urls = volume.pageFiles.indices.compactMap { volume.pageURL(at: $0) }
        let step = max(urls.count / 12, 1)
        let sample = stride(from: 0, to: urls.count, by: step).map { urls[$0] }
        let isTall = await Task.detached(priority: .utility) {
            isTallStrip(sample.map(PageMetrics.pixelSize))
        }.value
        cache[volume.id] = isTall
        return isTall
    }
}

extension Series {
    /// The mode the reader will use: the saved one, else Vertical Scroll for a
    /// detected webtoon, else the default from Settings.
    func displayReadingMode(default defaultMode: ReadingMode, isWebtoon: Bool) -> ReadingMode {
        readingMode ?? (isWebtoon && WebtoonDetector.isEnabled ? .vertical : defaultMode)
    }
}

// MARK: - Page metrics

nonisolated enum PageMetrics {
    static let animatableExtensions: Set<String> = ["gif", "apng", "png", "webp"]
    /// Larger animations stay still: every frame is decoded at full size.
    static let maxAnimatedSide: CGFloat = 2048

    /// True for a GIF, APNG or WebP with more than one frame, no larger than `maxAnimatedSide`.
    static func isAnimated(_ url: URL, size: CGSize?) -> Bool {
        guard animatableExtensions.contains(url.pathExtension.lowercased()),
              let size, max(size.width, size.height) <= maxAnimatedSide,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Pixel size from the image header, with EXIF rotation applied. Decodes nothing.
    static func pixelSize(of url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        // Orientations 5...8 are rotated by 90°.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Pairs pages for a two-page spread.
    /// The first page (the cover) stands alone. A wide page (already a double spread)
    /// stands alone. The rest go in pairs: [0] [1,2] [3,4] …
    static func spreads(count: Int, isWide: (Int) -> Bool) -> [[Int]] {
        guard count > 0 else { return [] }
        var groups: [[Int]] = [[0]]
        var index = 1
        while index < count {
            if isWide(index) || index + 1 >= count || isWide(index + 1) {
                groups.append([index])
                index += 1
            } else {
                groups.append([index, index + 1])
                index += 2
            }
        }
        return groups
    }
}
