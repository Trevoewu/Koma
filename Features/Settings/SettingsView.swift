import SwiftUI
import SwiftData

/// Settings → Appearance.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

/// The Settings sheet (the Settings board): Appearance, Reading, Storage,
/// Help & Feedback and About, each a section card with 44 pt icon rows.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .dark
    @AppStorage(SettingsKey.defaultReadingMode) private var defaultMode: ReadingMode = .rightToLeft
    @AppStorage(SettingsKey.detectWebtoons) private var detectWebtoons = true
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = false
    @AppStorage(SettingsKey.showAdultSources) private var showsAdultSources = false
    @State private var confirmsAdultSources = false

    @Query(filter: #Predicate<Volume> { $0.isFinished }) private var finishedVolumes: [Volume]
    @Query private var allVolumes: [Volume]

    @State private var storage: StorageInfo?
    @State private var confirmsDeleteFinished = false
    @State private var showsGuide = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appearanceSection
                    readingSection
                    librarySection
                    sourcesSection
                    storageSection
                    helpSection
                    aboutSection
                    #if DEBUG
                    developerSection
                    #endif
                }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.sheetGradient)
        // A sheet that is already open does not follow the app root, so it applies the choice itself.
        .preferredColorScheme(appearance.colorScheme)
        .task(id: allVolumes.count) { storage = await StorageInfo.load() }
        .sheet(isPresented: $showsGuide) { ImportGuideView() }
        .confirmationDialog("Delete \(finishedVolumes.count) finished volumes?",
                            isPresented: $confirmsDeleteFinished, titleVisibility: .visible) {
            Button("Delete Finished Volumes", role: .destructive, action: deleteFinished)
        } message: {
            Text("Their pages are removed from this device. Series with no volumes left are removed too.")
        }
    }

    // MARK: Sections

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Appearance"))
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
        }
        .sectionCard()
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource("settings.reading", defaultValue: "Reading",
                                               comment: "Settings section about reading. Not the library filter."))
            Menu {
                Picker("Default Direction", selection: $defaultMode) {
                    ForEach(ReadingMode.allCases) { mode in
                        Label { Text(mode.title) } icon: { Image(systemName: mode.systemImage) }.tag(mode)
                    }
                }
            } label: {
                SettingsRow(systemImage: defaultMode.systemImage, title: "Default Direction",
                            subtitle: Text(defaultMode.title)) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(Theme.iconWellFill, in: .circle)
                }
            }
            .buttonStyle(.plain)

            SettingsRow(systemImage: "arrow.down", title: "Detect Webtoons",
                        subtitle: Text("Tall pages open in Vertical Scroll")) {
                Toggle("Detect Webtoons", isOn: $detectWebtoons).labelsHidden().tint(Theme.switchOn)
            }
            SettingsRow(systemImage: "sun.max", title: "Keep Screen On",
                        subtitle: Text("While a book is open")) {
                Toggle("Keep Screen On", isOn: $keepScreenOn).labelsHidden().tint(Theme.switchOn)
            }
        }
        .sectionCard()
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Library"))
            NavigationLink {
                TagManagerView()
                    .background(Theme.sheetGradient)
            } label: {
                SettingsRow(systemImage: "tag", title: "Tags",
                            subtitle: Text("Add, rename or delete tags")) { chevron }
            }
            .buttonStyle(.plain)
        }
        .sectionCard()
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Sources"))
            SettingsRow(systemImage: "eye.slash", title: "Show Adult Sources",
                        subtitle: Text("Sources for mainly adult content")) {
                Toggle("Show Adult Sources", isOn: Binding(
                    get: { showsAdultSources },
                    set: { newValue in
                        // Turning it on needs an age confirmation. Turning it off does not.
                        if newValue { confirmsAdultSources = true } else { showsAdultSources = false }
                    }))
                    .labelsHidden()
                    .tint(Theme.switchOn)
            }
        }
        .sectionCard()
        .confirmationDialog("Show Adult Sources?", isPresented: $confirmsAdultSources, titleVisibility: .visible) {
            Button("I Am 18 or Older") { showsAdultSources = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These sources are for adult content. Turn this on only if you are 18 or older.")
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Storage"))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Library").font(.body.weight(.semibold))
                    Spacer()
                    Text(storage.map { $0.usedBytes.formatted(.byteCount(style: .file)) } ?? "–")
                        .foregroundStyle(Theme.secondaryText)
                }
                ReadingProgressBar(value: storage?.usedFraction ?? 0, height: 8)
                Text(storageLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(14)
            .accessibilityElement(children: .combine)

            Button {
                confirmsDeleteFinished = true
            } label: {
                Text("Delete Finished Volumes…")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .padding(14)
                    .foregroundStyle(Color.dynamic(light: 0xD70015, dark: 0xFF6961))
                    .background(Color.red.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.row))
            }
            .buttonStyle(.plain)
            .disabled(finishedVolumes.isEmpty)
            .opacity(finishedVolumes.isEmpty ? 0.5 : 1)
        }
        .sectionCard()
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Help & Feedback"))
            Button { showsGuide = true } label: {
                SettingsRow(systemImage: "questionmark", title: "Import Guide",
                            subtitle: Text("How to add ZIP, CBZ and EPUB files")) { chevron }
            }
            .buttonStyle(.plain)
            if let url = AppInfo.feedbackURL {
                Link(destination: url) {
                    SettingsRow(systemImage: "envelope", title: "Send Feedback",
                                subtitle: Text("Opens Mail")) { chevron }
                }
                .buttonStyle(.plain)
            }
        }
        .sectionCard()
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(LocalizedStringResource(stringLiteral: "About"))
            SettingsRow(systemImage: "book.closed", title: "Koma",
                        subtitle: Text("Version \(AppInfo.version)")) { EmptyView() }
            SettingsRow(systemImage: "hand.raised", title: "Privacy",
                        subtitle: Text("Your library stays on this device. Koma collects no data.")) { EmptyView() }
            Text("Only import manga you are allowed to use.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 4)
        }
        .sectionCard()
    }

    #if DEBUG
    @Query private var allSeries: [Series]

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(LocalizedStringResource(stringLiteral: "Developer"))
            Button("Add Sample Data", systemImage: "wand.and.stars") {
                SampleData.insert(into: context)
            }
            .buttonStyle(.glass)
            Button("Add 1,050 Test Volumes", systemImage: "square.stack.3d.up") {
                SampleData.insertLarge(into: context)
            }
            .buttonStyle(.glass)
            Button("Delete All Series", systemImage: "trash", role: .destructive) {
                for series in allSeries { LibraryActions.delete(series, in: context) }
            }
            .buttonStyle(.glass)
        }
        .sectionCard()
    }
    #endif

    // MARK: Parts

    private func sectionTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 32, height: 32)
            .background(Theme.iconWellFill, in: .circle)
            .accessibilityHidden(true)
    }

    /// "81 volumes · 14.6 GB free"
    private var storageLine: String {
        let volumes = String(localized: "\(allVolumes.count) volumes")
        guard let free = storage?.freeBytes else { return volumes }
        return volumes + " · " + String(localized: "\(free.formatted(.byteCount(style: .file))) free")
    }

    private func deleteFinished() {
        for volume in finishedVolumes {
            let series = volume.series
            try? LibraryPaths.deleteFiles(for: volume.id)
            context.delete(volume)
            if let series, (series.volumes ?? []).allSatisfy({ $0 === volume || $0.isDeleted }) {
                context.delete(series)
            }
        }
        try? context.save()
    }
}

/// A Settings row: icon in a 44 pt round well, title, gray subtitle, and a trailing control.
struct SettingsRow<Trailing: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: Text
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Theme.iconWellFill, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(.rect(cornerRadius: Theme.Radius.row))
        .accessibilityElement(children: .combine)
    }
}

/// Disk use of the library folder and free space on the device.
struct StorageInfo: Sendable {
    var usedBytes: Int64
    var freeBytes: Int64?

    /// Library size as a part of (library + free space).
    var usedFraction: Double {
        guard let freeBytes, usedBytes + freeBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(usedBytes + freeBytes)
    }

    static func load() async -> StorageInfo {
        await Task.detached(priority: .utility) { measure() }.value
    }

    nonisolated static func measure() -> StorageInfo {
        var used: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let files = FileManager.default.enumerator(at: LibraryPaths.root, includingPropertiesForKeys: keys) {
            while let url = files.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { used += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return StorageInfo(usedBytes: used, freeBytes: free)
    }
}

/// Facts about the app for the About section.
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Set a support address before release. The row is hidden while this is empty.
    static let feedbackEmail = ""

    static var feedbackURL: URL? {
        feedbackEmail.isEmpty ? nil : URL(string: "mailto:\(feedbackEmail)?subject=Koma%20\(version)")
    }
}
