import SwiftUI
import SwiftData

/// The reader. Black background, pages edge to edge, glass controls floating on top.
/// Present it full screen: `.fullScreenCover(item:) { ReaderView(volume: $0) }`.
struct ReaderView: View {
    @State private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = false

    init(volume: Volume) {
        _model = State(initialValue: ReaderModel(volume: volume))
    }

    var body: some View {
        ZStack {
            Color.black

            if model.pageCount == 0 {
                // Fixed reader colors: EmptyStateView would follow a light app setting.
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.Reader.secondaryText)
                        .accessibilityHidden(true)
                    Text("No Pages")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.Reader.primaryText)
                    Text("The pages of this volume are missing. Import it again.")
                        .font(.callout)
                        .foregroundStyle(Theme.Reader.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                GeometryReader { geo in
                    pages
                        .onAppear { updateViewport(geo.size) }
                        .onChange(of: geo.size) { updateViewport(geo.size) }
                }
            }
        }
        .ignoresSafeArea()
        .overlay {
            ReaderControls(model: model, isWide: sizeClass == .regular) { close() }
        }
        // System controls (menus, popover) follow this. Our own colors use Theme.Reader.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!model.controlsVisible)
        .persistentSystemOverlays(model.controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .task { await model.loadPageSizes() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        .onDisappear {
            model.saveNow()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .accessibilityAction(named: "Next Page") { model.next() }
        .accessibilityAction(named: "Previous Page") { model.previous() }
    }

    @ViewBuilder
    private var pages: some View {
        if model.mode == .vertical {
            VerticalReader(model: model)
        } else {
            PagedReader(model: model)
        }
    }

    private func updateViewport(_ size: CGSize) {
        model.updateViewport(size, scale: displayScale, isRegularWidth: sizeClass == .regular)
    }

    private func close() {
        model.saveNow()
        dismiss()
    }
}
