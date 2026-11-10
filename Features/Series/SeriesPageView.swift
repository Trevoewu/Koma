import SwiftUI
import SwiftData

/// The one page for a series: a library series (imported or downloaded from a source)
/// and a manga found in Browse.
///
/// Layout: cover beside title, author (tap → other series by this author), info line,
/// summary, tags (tap → all series with the tag, dashed "+ Tag"), one white button,
/// then the list: chapters from the source, or the volumes of an imported series.
/// A library series has Edit and a "…" menu. Source details are cached on the series
/// (SourceLibraryCache), so the page opens at once and works offline.
struct SeriesPageView: View {
    @Environment(SourceManager.self) private var manager
    @Environment(SourceDownloads.self) private var downloads
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.defaultReadingMode) private var defaultMode: ReadingMode = .rightToLeft

    /// The library series. nil for a manga from Browse that has no downloads yet.
    @State private var series: Series?
    /// The source manga with its chapters. nil for an imported series.
    @State private var manga: SourceManga?
    @State private var sourceID: String?
    private let routeSource: SourceInfo?

    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Downloaded chapters by chapter key. Filled by refreshDownloaded(), never in body:
    /// a SwiftData fetch per row on every redraw kept the main thread busy.
    @State private var downloadedVolumes: [String: Volume] = [:]
    @State private var showsFullSummary = false
    @State private var readingVolume: Volume?
    @State private var newestFirst = true
    @State private var tint = SeriesTint.neutral
    /// Settings → Detect Webtoons, checked on the volume that Continue opens.
    @State private var isWebtoon = false

    @State private var showsEdit = false
    @State private var showsTagPicker = false
    @State private var shareRequest: SeriesShare.Request?
    @State private var confirmsDeleteSeries = false
    @State private var volumeToDelete: Volume?
    /// Set while the page closes after a delete, so nothing reads the deleted models.
    @State private var isDeleted = false

    /// From the library.
    init(series: Series) {
        _series = State(initialValue: series)
        _sourceID = State(initialValue: series.sourceID)
        let cached = SourceLibraryCache.manga(for: series)
        _manga = State(initialValue: cached ?? series.sourceMangaKey.map { SourceManga(key: $0, title: series.title) })
        routeSource = nil
    }

    /// From Browse.
    init(route: SourceMangaRoute) {
        _manga = State(initialValue: route.manga)
        _sourceID = State(initialValue: route.source.id)
        routeSource = route.source
    }

    /// The installed source. nil for an imported series, or when the source was removed:
    /// then the downloaded chapters show as volumes.
    private var source: SourceInfo? {
        if let routeSource { return routeSource }
        guard let sourceID else { return nil }
        return manager.installed.first { $0.id == sourceID }
    }

    /// The source part of the page is shown.
    private var isSource: Bool { source != nil && manga != nil }

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isDeleted {
                Color.clear
            } else {
                content
            }
        }
        .background {
            if series != nil { SeriesBackground(tint: tint) } else { ScreenBackground() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !isDeleted { toolbar } }
        .task { await load() }
        .task(id: series?.coverURL) {
            if let series { tint = await SeriesTint.load(for: series) }
        }
        .task(id: detectionVolume?.id) {
            guard !isSource, let series, series.readingMode == nil, let volume = detectionVolume else { return }
            isWebtoon = await WebtoonDetector.isWebtoon(volume)
        }
        .onChange(of: downloads.progress.count) { refreshDownloaded() }
        .fullScreenCover(item: $readingVolume, onDismiss: refreshDownloaded) { ReaderView(volume: $0) }
        .sheet(isPresented: $showsEdit) { if let series { SeriesEditView(series: series) } }
        .seriesShareSheet($shareRequest)
        .sheet(isPresented: $showsTagPicker) {
            if let series {
                TagPickerView(selection: Binding(
                    get: { series.sortedTagNames },
                    set: { names in
                        SeriesActions.setTags(names, on: series, in: context)
                        try? context.save()
                    }))
            }
        }
        .confirmationDialog("Delete “\(series?.title ?? "")”?", isPresented: $confirmsDeleteSeries, titleVisibility: .visible) {
            Button("Delete Series", role: .destructive, action: deleteSeries)
        } message: {
            Text("This removes \(series?.volumeCount ?? 0) volumes and their pages from this device.")
        }
        .confirmationDialog("Delete \(volumeToDelete?.displayName ?? "")?", isPresented: volumeDialogBinding,
                            titleVisibility: .visible, presenting: volumeToDelete) { volume in
            Button("Delete Volume", role: .destructive) { deleteVolume(volume) }
        } message: { _ in
            Text("Its pages are removed from this device.")
        }
        .alert("Could Not Download", isPresented: downloadErrorBinding) {
            Button("OK", role: .cancel) { downloads.clearError() }
        } message: {
            Text(downloads.lastError ?? "")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let summary = summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(Theme.bodyText)
                        .lineLimit(showsFullSummary ? nil : 4)
                        .onTapGesture { withAnimation { showsFullSummary.toggle() } }
                }
                tags
                primaryButton
                if isSource {
                    chapterList
                } else if let series {
                    volumeList(series)
                }
            }
            .padding(.horizontal, isWide ? 40 : 20)
            .padding(.vertical, 8)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
    }

    // MARK: Header

    private var title: String { series?.title ?? manga?.title ?? "" }

    /// The user's edits win over the source.
    private var summary: String? { series?.summary.nonEmpty ?? manga?.summary.nonEmpty }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let local = series?.coverURL {
                    CoverView(title: title, imageURL: local)
                } else if let source {
                    RemoteCoverView(title: title, url: manga?.cover, sourceID: source.id)
                } else {
                    CoverView(title: title)
                }
            }
            .frame(width: isWide ? 160 : 118)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                author
                ForEach(infoLines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    /// Tap → other series by this author (only for a library series).
    @ViewBuilder
    private var author: some View {
        if let series, let name = series.author, !name.isEmpty {
            NavigationLink(value: AuthorRoute(name: name)) {
                HStack(spacing: 4) {
                    Text(name)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityHint("Shows other series by this author")
        } else if let creators = manga?.creatorLine {
            Text(creators)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// Source: "Ongoing", "MANGA Plus · English".
    /// Imported: "8 volumes · 1412 pages · Right to Left".
    private var infoLines: [String] {
        if isSource, let source {
            var lines: [String] = []
            if let status = statusText { lines.append(status) }
            lines.append([source.name, languageLine].compactMap { $0 }.joined(separator: " · "))
            return lines
        }
        guard let series else { return [] }
        return [[String(localized: "\(series.volumeCount) volumes"),
                 String(localized: "\(series.totalPages) pages"),
                 String(localized: series.displayReadingMode(default: defaultMode, isWebtoon: isWebtoon).title)]
            .joined(separator: " · ")]
    }

    private var statusText: String? {
        switch manga?.status {
        case .ongoing: String(localized: "Ongoing")
        case .completed: String(localized: "Completed")
        case .cancelled: String(localized: "Cancelled")
        case .hiatus: String(localized: "On Hiatus")
        default: nil
        }
    }

    /// The language of the manga: from its chapters, else the language the source
    /// is set to read, else the source's only language.
    private var languageLine: String? {
        guard let source else { return nil }
        var codes: [String] = []
        for code in chapters.compactMap(\.language) where !codes.contains(code) { codes.append(code) }
        if codes.isEmpty { codes = manager.selectedLanguages(of: source.id) }
        if codes.isEmpty, source.languages.count == 1 { codes = source.languages }
        guard !codes.isEmpty else { return nil }
        return SourceLanguages.label(codes)
    }

    // MARK: Tags

    /// A library series: its own tags, tappable, with "+ Tag". A manga from Browse: the source's tags.
    @ViewBuilder
    private var tags: some View {
        if let series {
            FlowLayout(spacing: 8, centered: false) {
                ForEach(series.sortedTagNames, id: \.self) { name in
                    NavigationLink(value: TagRoute(name: name)) {
                        // 44 pt touch target; the layout keeps the 30 pt chip.
                        TagChip(name: name)
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                            .padding(.vertical, -7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows all series with this tag")
                }
                AddTagChip { showsTagPicker = true }
            }
        } else if let tags = manga?.tags, !tags.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) { ForEach(tags, id: \.self) { TagChip(name: $0) } }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Primary button

    @ViewBuilder
    private var primaryButton: some View {
        if isSource {
            sourceReadButton
        } else if let series {
            if let volume = series.continueVolume {
                Button { readingVolume = volume } label: {
                    Label(volume.hasStarted
                          ? String(localized: "Continue · p. \(volume.currentPage + 1)")
                          : String(localized: "Start Reading"),
                          systemImage: "play.fill")
                }
                .buttonStyle(.primaryFullWidth)
            } else if let first = series.sortedVolumes.first {
                Button {
                    first.currentPage = 0
                    readingVolume = first
                } label: {
                    Label("Read Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.primaryFullWidth)
            }
        }
    }

    // MARK: Volumes (imported series, or a source that was removed)

    private func volumeList(_ series: Series) -> some View {
        let current = series.continueVolume
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(series.volumeCount) volumes")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .frame(minHeight: 44)
            LazyVStack(spacing: 0) {
                ForEach(series.sortedVolumes) { volume in
                    volumeRow(volume, isCurrent: volume === current)
                    Divider().overlay(Theme.sectionStroke)
                }
            }
        }
    }

    private func volumeRow(_ volume: Volume, isCurrent: Bool) -> some View {
        Button { readingVolume = volume } label: {
            HStack(spacing: 12) {
                CoverView(title: volume.displayName, imageURL: volume.coverURL, cornerRadius: 6)
                    .frame(width: 40)
                    .shadow(radius: 0)
                    .opacity(volume.isFinished ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.nameBesideSeries(long: true) ?? volume.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(volume.isFinished ? Theme.tertiaryText : Theme.primaryText)
                        .lineLimit(2)
                    Text(volume.hasStarted && !volume.isFinished
                         ? String(localized: "Page \(volume.currentPage + 1) of \(volume.pageCount)")
                         : String(localized: "\(volume.pageCount) pages"))
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                volumeStatus(volume, isCurrent: isCurrent)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { volumeMenu(volume) }
    }

    @ViewBuilder
    private func volumeStatus(_ volume: Volume, isCurrent: Bool) -> some View {
        if volume.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Finished")
        } else if volume.hasStarted {
            ReadingRing(progress: volume.progress)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private func volumeMenu(_ volume: Volume) -> some View {
        if volume.isFinished || volume.hasStarted {
            Button("Mark as Unread", systemImage: "circle") { SeriesActions.markUnread(volume) }
        }
        if !volume.isFinished {
            Button("Mark as Read", systemImage: "checkmark.circle") { LibraryActions.markFinished(volume) }
        }
        Button("Delete Volume…", systemImage: "trash", role: .destructive) { volumeToDelete = volume }
    }

    private var detectionVolume: Volume? { series?.continueVolume ?? series?.sortedVolumes.first }

    // MARK: Chapters (source)

    private var chapters: [SourceChapter] { manga?.chapters ?? offlineChapters }

    /// The downloaded chapters, when the source has never sent a chapter list.
    private var offlineChapters: [SourceChapter] {
        downloadedVolumes.values.sorted(by: Volume.readingOrder).reversed().compactMap { volume in
            volume.sourceChapterKey.map {
                SourceChapter(key: $0, title: volume.title, chapterNumber: volume.number.map(Float.init))
            }
        }
    }

    /// Sources list chapters newest first. Reading starts at the oldest unread one.
    private var readingOrder: [SourceChapter] {
        chapters.filter { !$0.locked }.sorted { a, b in
            switch (a.chapterNumber, b.chapterNumber) {
            case let (x?, y?) where x != y: return x < y
            default: return (chapters.firstIndex(of: a) ?? 0) > (chapters.firstIndex(of: b) ?? 0)
            }
        }
    }

    /// The chapter the button opens: after the last downloaded chapter the user read.
    private var nextChapter: (chapter: SourceChapter, isContinue: Bool)? {
        let order = readingOrder
        let volumes = order.compactMap { chapter in downloadedVolumes[chapter.key].map { (chapter, $0) } }
        if let current = volumes.filter({ $0.1.lastReadAt != nil }).max(by: { $0.1.lastReadAt! < $1.1.lastReadAt! }) {
            if !current.1.isFinished { return (current.0, true) }
            if let index = order.firstIndex(of: current.0), order.indices.contains(index + 1) {
                return (order[index + 1], true)
            }
        }
        return order.first.map { ($0, false) }
    }

    @ViewBuilder
    private var sourceReadButton: some View {
        if let next = nextChapter, let key = downloadKey(next.chapter) {
            Button {
                open(next.chapter)
            } label: {
                if let progress = downloads.progress[key] {
                    Label {
                        Text("Downloading \(progress, format: .percent.precision(.fractionLength(0)))")
                            .monospacedDigit()
                    } icon: {
                        DownloadRing(progress: progress, color: Theme.onPrimary)
                    }
                } else if next.isContinue {
                    Label("Continue · \(next.chapter.numberLabel ?? next.chapter.displayTitle)", systemImage: "play.fill")
                } else {
                    Label("Start Reading", systemImage: "play.fill")
                }
            }
            .buttonStyle(.primaryFullWidth)
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        if isLoading, chapters.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if chapters.isEmpty, let errorMessage {
            loadError(errorMessage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(chapters.count) Chapters")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Button(newestFirst ? "Newest First" : "Oldest First",
                           systemImage: "arrow.up.arrow.down") { newestFirst.toggle() }
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(minHeight: 44)
                }
                LazyVStack(spacing: 0) {
                    ForEach(newestFirst ? chapters : chapters.reversed()) { chapter in
                        chapterRow(chapter)
                        Divider().overlay(Theme.sectionStroke)
                    }
                }
            }
        }
    }

    private func loadError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await load() } }
                .buttonStyle(.glass)
        }
    }

    private func chapterRow(_ chapter: SourceChapter) -> some View {
        let volume = downloadedVolumes[chapter.key]
        return Button {
            open(chapter)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(volume?.isFinished == true ? Theme.tertiaryText : Theme.primaryText)
                        .lineLimit(2)
                    if let detail = detailText(chapter) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chapterStatus(chapter, volume: volume)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(chapter.locked)
        .opacity(chapter.locked ? 0.5 : 1)
        .contextMenu {
            if let volume {
                volumeMenu(volume)
            } else if !chapter.locked {
                Button("Download", systemImage: "arrow.down.circle") { download(chapter) }
            }
        }
    }

    @ViewBuilder
    private func chapterStatus(_ chapter: SourceChapter, volume: Volume?) -> some View {
        if chapter.locked {
            Image(systemName: "lock.fill")
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Locked")
        } else if let key = downloadKey(chapter), let progress = downloads.progress[key] {
            DownloadRing(progress: progress, color: Theme.secondaryText)
                .frame(width: 44, height: 44)
        } else if let volume {
            if volume.hasStarted, !volume.isFinished {
                ReadingRing(progress: volume.progress)
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Downloaded")
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") { download(chapter) }
                .labelStyle(.iconOnly)
                .font(.system(size: 20))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
                .buttonStyle(.plain)
        }
    }

    private func detailText(_ chapter: SourceChapter) -> String? {
        var parts: [String] = []
        if let date = chapter.uploadDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let scanlators = chapter.scanlators, !scanlators.isEmpty { parts.append(scanlators.joined(separator: ", ")) }
        if let language = chapter.language, (source?.languages.count ?? 0) > 1 {
            parts.append(Locale.current.localizedString(forIdentifier: language) ?? language)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let series {
            ToolbarItem(placement: .topBarTrailing) {
                // The board shows icon and text. A toolbar turns any Label into its icon.
                Button { showsEdit = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                    .padding(.horizontal, 6)
                }
                .accessibilityLabel("Edit")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share…", systemImage: "square.and.arrow.up") {
                        shareRequest = SeriesShare.request(for: series)
                    }
                    Divider()
                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                        SeriesActions.markAll(series, read: true)
                    }
                    Button("Mark All as Unread", systemImage: "circle") {
                        SeriesActions.markAll(series, read: false)
                    }
                    Divider()
                    Button("Delete Series…", systemImage: "trash", role: .destructive) {
                        confirmsDeleteSeries = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        } else if let url = manga?.url.flatMap(URL.init(string:)) {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    // MARK: Actions

    private func downloadKey(_ chapter: SourceChapter) -> SourceDownloads.Key? {
        guard let source, let manga else { return nil }
        return SourceDownloads.Key(sourceID: source.id, mangaKey: manga.key, chapterKey: chapter.key)
    }

    private func open(_ chapter: SourceChapter) {
        guard let source, let manga else { return }
        Task {
            if let volume = await downloads.download(chapter, of: manga, source: source,
                                                     manager: manager, context: context) {
                refreshDownloaded()
                readingVolume = volume
            }
        }
    }

    private func download(_ chapter: SourceChapter) {
        guard let source, let manga else { return }
        Task {
            await downloads.download(chapter, of: manga, source: source, manager: manager, context: context)
            refreshDownloaded()
        }
    }

    /// Finds the library series and its downloaded chapters again.
    private func refreshDownloaded() {
        guard !isDeleted else { return }
        if let series, series.isDeleted { self.series = nil }
        guard let sourceID, let key = manga?.key ?? series?.sourceMangaKey else { return }
        downloadedVolumes = SourceDownloads.downloadedVolumes(sourceID: sourceID, mangaKey: key, in: context)
        if series == nil {
            let descriptor = FetchDescriptor<Series>(predicate: #Predicate {
                $0.sourceID == sourceID && $0.sourceMangaKey == key
            })
            series = try? context.fetch(descriptor).first
        }
    }

    /// Shows the cache at once, then asks the source for fresh details.
    private func load() async {
        refreshDownloaded()
        guard let source, let current = manga else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let runner = try await manager.runner(for: source.id)
            let fresh = try await runner.mangaDetails(current)
            manga = fresh
            errorMessage = nil
            if let series, !series.isDeleted {
                await SourceLibraryCache.store(fresh, in: series, manager: manager)
            }
        } catch {
            // Offline: the cached details and chapters stay on screen.
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Delete

    private var volumeDialogBinding: Binding<Bool> {
        Binding(get: { volumeToDelete != nil }, set: { if !$0 { volumeToDelete = nil } })
    }

    private var downloadErrorBinding: Binding<Bool> {
        Binding(get: { downloads.lastError != nil }, set: { if !$0 { downloads.clearError() } })
    }

    private func deleteVolume(_ volume: Volume) {
        if SeriesActions.delete(volume, in: context) {
            deleteSeries()
        } else {
            refreshDownloaded()
        }
    }

    /// Imported series: closes the page first, then deletes, so no view reads a deleted model.
    /// Source series: the page stays and shows the source again.
    private func deleteSeries() {
        guard let series else { return }
        if isSource {
            self.series = nil
            downloadedVolumes = [:]
            LibraryActions.delete(series, in: context)
            return
        }
        isDeleted = true
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            LibraryActions.delete(series, in: context)
        }
    }
}

/// A small ring that fills while a chapter downloads.
struct DownloadRing: View {
    let progress: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// How far the user read a volume or chapter.
struct ReadingRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(Theme.primaryText, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel("Reading")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}
