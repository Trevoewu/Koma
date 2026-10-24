import SwiftUI
import SwiftData

@main
struct KomaApp: App {
    @State private var importController = ImportController()
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .dark

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(importController)
                // Dark is the default look. Settings → Appearance changes it.
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(for: [Series.self, Volume.self, Tag.self])
    }
}
