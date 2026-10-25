import SwiftUI
import SwiftData

/// The native iOS 26 floating glass tab bar: Library, History and Search.
/// On iPad it shows as the tab bar at the top, with no sidebar.
struct RootView: View {
    enum AppTab: Hashable { case library, history, search }

    @State private var selection: AppTab = .library
    @Environment(ImportController.self) private var importController
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var importController = importController
        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView()
            }
            Tab("History", systemImage: "clock", value: .history) {
                HistoryView()
            }
            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        // The design marks the selected tab in white (black in light mode), not system blue.
        .tint(Theme.primaryText)
        // "Open in", the share sheet and AirDrop. Several files arrive as several calls;
        // the import controller queues them. The progress card shows in the Library tab.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            selection = .library
            importController.start([url], context: context, opensWhenDone: true)
        }
        // A file opened with Koma opens in the reader once it is imported.
        .fullScreenCover(item: $importController.volumeToOpen) { ReaderView(volume: $0) }
    }
}

#if DEBUG
#Preview {
    RootView()
        .modelContainer(SampleData.makeContainer())
        .environment(ImportController())
        .preferredColorScheme(.dark)
}
#endif
