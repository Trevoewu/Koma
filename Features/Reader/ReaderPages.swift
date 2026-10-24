import SwiftUI

/// Right to Left and Left to Right: a horizontal paging scroll view of page groups.
/// In right-to-left mode the scroll view is mirrored, so page 1 is on the right
/// and the user swipes to the right for the next page.
struct PagedReader: View {
    @Bindable var model: ReaderModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.groups.indices, id: \.self) { index in
                        let group = model.groups[index]
                        ZoomablePageView(images: group.map { model.cache.images[$0] },
                                         aspectRatios: group.map(model.aspectRatio(of:)),
                                         urls: group.map { model.pageURLs[$0] },
                                         animated: group.map(model.isAnimated),
                                         rightToLeft: model.isRightToLeft,
                                         isActive: index == model.groupPosition,
                                         onTap: model.handleTap)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(index)
                            .accessibilityElement()
                            .accessibilityLabel(Text("Page \(model.pageLabel(for: group))"))
                            .accessibilityAddTraits(.isImage)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $model.groupPosition)
            .scrollIndicators(.hidden)
            .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
            .id(model.layoutID)
            .onChange(of: model.groupPosition) { model.groupPositionChanged() }
            // A new scroll view ignores the starting value of scrollPosition, so scroll by hand
            // after the first layout (on open, mode change and rotation).
            .task(id: model.layoutID) {
                if let group = model.takeRestoreTarget(vertical: false) { proxy.scrollTo(group) }
            }
        }
    }
}

/// Vertical Scroll: pages stacked at full width, for webtoons.
///
/// Tap zones, like the paged modes: left 30% scrolls up one screen, center 40% shows
/// or hides the controls, right 30% scrolls down one screen. One screen is 85% of the
/// height, so a line of the last screen stays in view.
struct VerticalReader: View {
    @Bindable var model: ReaderModel

    @State private var position = ScrollPosition(idType: Int.self)
    @State private var offset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// Top edge of each page that is laid out now, in content coordinates.
    @State private var pageTops: [Int: CGFloat] = [:]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(0..<model.pageCount, id: \.self) { page in
                    VerticalPage(image: model.cache.images[page], aspectRatio: model.aspectRatio(of: page),
                                 animatedURL: model.isAnimated(page) ? model.pageURLs[page] : nil)
                        .id(page)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { top in
                            pageTops[page] = top
                            updateCurrentPage()
                        }
                        .onDisappear { pageTops[page] = nil }
                        .accessibilityLabel(Text("Page \(model.pageLabel(for: [page]))"))
                }
            }
            .coordinateSpace(.named(Self.space))
            .scrollTargetLayout()
        }
        .scrollPosition($position, anchor: .top)
        .scrollIndicators(.hidden)
        .id(model.layoutID)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                          viewport: geometry.containerSize.height,
                          width: geometry.containerSize.width,
                          content: geometry.contentSize.height)
        } action: { _, metrics in
            offset = metrics.offset
            viewportHeight = metrics.viewport
            viewportWidth = metrics.width
            contentHeight = metrics.content
            updateCurrentPage()
        }
        .onTapGesture(coordinateSpace: .local) { location in
            handleTap(atX: location.x)
        }
        .onChange(of: model.verticalScrollRequest) { _, request in
            if let request { position.scrollTo(id: request.page, anchor: .top) }
        }
        // A new scroll view starts at the top, so scroll to the saved page after
        // the first layout (on open and on a mode change).
        .task(id: model.layoutID) {
            if let page = model.takeRestoreTarget(vertical: true) { position.scrollTo(id: page, anchor: .top) }
        }
    }

    private static let space = "verticalPages"

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat
        var viewport: CGFloat
        var width: CGFloat
        var content: CGFloat
    }

    private func handleTap(atX x: CGFloat) {
        guard viewportWidth > 0, viewportHeight > 0 else { return model.handleTap(.center) }
        let fraction = x / viewportWidth
        if fraction < 0.3 {
            scrollByScreen(-1)
        } else if fraction > 0.7 {
            scrollByScreen(1)
        } else {
            model.handleTap(.center)
        }
    }

    private func scrollByScreen(_ direction: CGFloat) {
        let maxOffset = max(contentHeight - viewportHeight, 0)
        let target = min(max(offset + direction * viewportHeight * 0.85, 0), maxOffset)
        guard abs(target - offset) > 1 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            position.scrollTo(y: target)
            model.controlsVisible = false
            model.showsModeMenu = false
        }
    }

    /// The current page is the one that covers the line a quarter down the screen,
    /// so a thin strip of the page before it at the top does not count.
    private func updateCurrentPage() {
        let line = offset + viewportHeight * 0.25
        guard let page = pageTops.filter({ $0.value <= line }).max(by: { $0.key < $1.key })?.key,
              page != model.verticalPosition
        else { return }
        model.verticalPageChanged(to: page)
    }
}

private struct VerticalPage: View {
    let image: UIImage?
    let aspectRatio: CGFloat
    var animatedURL: URL?

    var body: some View {
        Group {
            if let animatedURL {
                AnimatedPageView(url: animatedURL, poster: image)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Color(white: 0.06)
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
    }
}
