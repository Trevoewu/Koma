import SwiftUI

/// The floating glass controls from the Reader boards.
///
/// iPhone: round back button, title capsule, and a capsule with mode + bookmark at the top;
/// a glass card with "42 / 186", the mode, the slider and a hint at the bottom.
/// iPad: one 640 pt capsule at the top (back, title, Two Pages, mode, bookmark)
/// and one at the bottom ("42–43 / 186", slider, mode).
struct ReaderControls: View {
    @Bindable var model: ReaderModel
    var isWide: Bool
    var onClose: () -> Void

    /// The page under the slider thumb while the user drags it.
    @State private var scrubPage: Int?

    var body: some View {
        VStack(spacing: 0) {
            if model.controlsVisible {
                (isWide ? AnyView(wideTopBar) : AnyView(compactTopBar))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if model.controlsVisible {
                (isWide ? AnyView(wideBottomBar) : AnyView(compactBottomCard))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text(model.pageLabel())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.mode == .vertical ? Color(hex: 0x6C6C70) : Theme.Reader.tertiaryText)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.25), value: model.controlsVisible)
    }

    // MARK: iPhone

    private var compactTopBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                GlassIconButton(systemImage: "chevron.left", label: "Back", size: 48, glass: Theme.readerGlass,
                                foreground: Theme.Reader.primaryText, action: onClose)
                titleStack
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glassEffect(Theme.readerGlass, in: .capsule)
                HStack(spacing: 0) {
                    modeButton
                    bookmarkButton
                }
                .padding(.horizontal, 2)
                .frame(height: 48)
                .glassEffect(Theme.readerGlass, in: .capsule)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var compactBottomCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pageLabel)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                Text(model.mode.title)
                    .font(.footnote)
                    .foregroundStyle(Theme.Reader.secondaryText)
            }
            slider
            Text(hint)
                .font(.footnote)
                .foregroundStyle(Theme.Reader.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .glassEffect(Theme.readerGlass, in: .rect(cornerRadius: 30))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: iPad

    private var wideTopBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Back")
            titleStack
                .frame(maxWidth: .infinity)
            if model.spreadsAvailable, model.mode != .vertical {
                Button {
                    model.prefersSpreads.toggle()
                } label: {
                    Label(model.prefersSpreads ? "Two Pages" : "One Page",
                          systemImage: model.prefersSpreads ? "book.pages" : "doc")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(model.prefersSpreads ? 0.14 : 0), in: .capsule)
                }
                .accessibilityLabel(model.prefersSpreads ? "Page layout: two pages" : "Page layout: one page")
            }
            modeButton
            bookmarkButton
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(width: 640, height: 60)
        .glassEffect(Theme.readerGlass, in: .capsule)
        .padding(.top, 8)
    }

    private var wideBottomBar: some View {
        HStack(spacing: 20) {
            Text(pageLabel)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .fixedSize()
            slider
            Text(model.mode.title)
                .font(.footnote)
                .foregroundStyle(Theme.Reader.secondaryText)
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .frame(width: 640, height: 60)
        .glassEffect(Theme.readerGlass, in: .capsule)
        .padding(.bottom, 12)
    }

    // MARK: Parts

    private var titleStack: some View {
        let seriesTitle = model.volume.series?.title ?? model.volume.title
        let volumeName = model.volume.longDisplayName
        return VStack(spacing: 1) {
            Text(seriesTitle)
                .font(.system(size: isWide ? 15 : 14, weight: .semibold))
            // A volume without a number is named after its file, often the same as the series.
            if volumeName.caseInsensitiveCompare(seriesTitle) != .orderedSame {
                Text(volumeName)
                    .font(.system(size: isWide ? 12 : 11))
                    .foregroundStyle(Theme.Reader.secondaryText)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private var modeButton: some View {
        Button {
            model.showsModeMenu.toggle()
        } label: {
            Image(systemName: model.mode.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(model.showsModeMenu ? 0.24 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reading Mode")
        .accessibilityValue(Text(model.mode.title))
        .popover(isPresented: $model.showsModeMenu, arrowEdge: .top) {
            ReadingModeMenu(selected: model.mode, onSelect: model.setMode)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var bookmarkButton: some View {
        Button(action: model.toggleBookmark) {
            Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isCurrentPageBookmarked ? "Remove Bookmark" : "Add Bookmark")
    }

    private var slider: some View {
        ReaderSlider(page: model.visiblePages.last ?? model.currentPage,
                     pageCount: model.pageCount,
                     fillsFromTrailing: model.isRightToLeft,
                     bookmarks: model.volume.bookmarkedPages,
                     scrubPage: $scrubPage,
                     onCommit: { model.jump(toPage: $0) })
    }

    private var pageLabel: String {
        if let scrubPage { return model.pageLabel(for: [scrubPage]) }
        return model.pageLabel()
    }

    private var hint: LocalizedStringKey {
        switch model.mode {
        case .rightToLeft: "Tap the left side for the next page."
        case .leftToRight: "Tap the right side for the next page."
        case .vertical:    "Scroll, or tap the left or right side to move. Tap the middle to hide controls."
        }
    }
}

/// The glass popover with the three reading modes.
struct ReadingModeMenu: View {
    let selected: ReadingMode
    var onSelect: (ReadingMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ReadingMode.allCases) { mode in
                Button { onSelect(mode) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.body)
                            Text(mode.subtitle)
                                .font(.footnote)
                                .foregroundStyle(Theme.Reader.secondaryText)
                        }
                        Spacer(minLength: 8)
                        if mode == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color(hex: 0x64A8FF))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 60)
                    .background(Color.white.opacity(mode == selected ? 0.12 : 0), in: .rect(cornerRadius: 20))
                    .contentShape(.rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == selected ? .isSelected : [])
            }
            Text("Saved for this series")
                .font(.caption)
                .foregroundStyle(Theme.Reader.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(width: 276)
    }
}

/// The page slider: a 4 pt track, a white fill and a 20 pt thumb.
/// In right-to-left mode it fills from the trailing (right) edge.
/// Small marks show bookmarked pages.
struct ReaderSlider: View {
    let page: Int
    let pageCount: Int
    let fillsFromTrailing: Bool
    var bookmarks: [Int] = []
    @Binding var scrubPage: Int?
    var onCommit: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = x(for: scrubPage ?? page, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.Reader.fill)
                    .frame(width: fillsFromTrailing ? width - thumbX : thumbX, height: 4)
                    .offset(x: fillsFromTrailing ? thumbX : 0)
                ForEach(bookmarks.filter { $0 < pageCount }, id: \.self) { mark in
                    Capsule()
                        .fill(Color(hex: 0x64A8FF))
                        .frame(width: 2, height: 10)
                        .offset(x: x(for: mark, width: width) - 1)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: thumbX - 10)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrubPage = page(at: $0.location.x, width: width) }
                    .onEnded {
                        onCommit(page(at: $0.location.x, width: width))
                        scrubPage = nil
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Page")
        .accessibilityValue(Text("\(page + 1) of \(pageCount)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(page + 1)
            case .decrement: onCommit(page - 1)
            @unknown default: break
            }
        }
    }

    private func fraction(for page: Int) -> CGFloat {
        pageCount > 1 ? CGFloat(page) / CGFloat(pageCount - 1) : 0
    }

    private func x(for page: Int, width: CGFloat) -> CGFloat {
        let f = fraction(for: page)
        return (fillsFromTrailing ? 1 - f : f) * width
    }

    private func page(at x: CGFloat, width: CGFloat) -> Int {
        var f = min(max(x / max(width, 1), 0), 1)
        if fillsFromTrailing { f = 1 - f }
        return Int((f * CGFloat(max(pageCount - 1, 0))).rounded())
    }
}
