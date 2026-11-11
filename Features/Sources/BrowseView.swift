import SwiftUI

/// The Browse tab: the installed sources. Tap a source to browse and search it.
/// Koma comes with no sources. The user adds a repository address in the sheet.
struct BrowseView: View {
    @Environment(SourceManager.self) private var manager
    @AppStorage(SettingsKey.showAdultSources) private var showsAdult = false
    @State private var showsRepositories = false
    @State private var sourceToRemove: SourceInfo?

    var body: some View {
        NavigationStack {
            Group {
                if visibleSources.isEmpty {
                    emptyState
                } else {
                    // One rounded group per language, rows separated by inset lines.
                    List {
                        ForEach(SourceLanguages.sections(visibleSources, languages: manager.readingLanguages, name: \.name)) { section in
                            Section {
                                ForEach(section.items) { source in
                                    NavigationLink(value: source) {
                                        InstalledSourceRow(source: source)
                                    }
                                    .listRowBackground(Theme.cardFill)
                                    .swipeActions {
                                        Button("Remove Source", systemImage: "trash", role: .destructive) {
                                            sourceToRemove = source
                                        }
                                    }
                                    .contextMenu {
                                        Button("Remove Source", systemImage: "trash", role: .destructive) {
                                            sourceToRemove = source
                                        }
                                    }
                                }
                            } header: {
                                LanguageHeader(title: section.title)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    // Same card width as the Sources sheet (a sheet and a tab get different defaults).
                    .contentMargins(.horizontal, Theme.Size.listMargin, for: .scrollContent)
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sources", systemImage: "plus") { showsRepositories = true }
                        .badge(manager.updates.count)
                }
            }
            .libraryDestinations()
        }
        .sheet(isPresented: $showsRepositories) { SourceCatalogView() }
        .task { await manager.refreshIndexes() }
        .confirmationDialog("Remove Source?", isPresented: removeDialogBinding, presenting: sourceToRemove) { source in
            Button("Remove \(source.name)", role: .destructive) { manager.uninstall(source.id) }
        } message: { _ in
            Text("Chapters you downloaded stay in your library.")
        }
    }

    /// Installed sources. Mainly adult ones only while Settings → Show Adult Sources is on.
    private var visibleSources: [SourceInfo] {
        showsAdult ? manager.installed : manager.installed.filter { $0.contentRating < 2 }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            GlassIconTile(systemImage: "puzzlepiece.extension", size: 72)
                .padding(.bottom, 10)
            Text("No Sources")
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
            Text("Add a source repository to browse manga from the web.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Add Sources", systemImage: "plus") { showsRepositories = true }
                .buttonStyle(.primary)
                .padding(.top, 14)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var removeDialogBinding: Binding<Bool> {
        Binding(get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } })
    }
}

struct InstalledSourceRow: View {
    let source: SourceInfo
    @Environment(SourceManager.self) private var manager

    var body: some View {
        HStack(spacing: 14) {
            SourceIcon(url: manager.iconURL(for: source.id), size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                // The section header names a single language.
                let languages = manager.readingLanguages(source)
                if languages.count > 1 {
                    Text(SourceLanguages.label(languages))
                        .font(.subheadline)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A rounded source icon. A local file for installed sources, a web image in repositories.
struct SourceIcon: View {
    var url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url, url.isFileURL {
                DownsampledImage(url: url) { placeholder }
            } else if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: size * 0.4))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: size, height: size)
            .background(Theme.iconWellFill)
    }
}

/// A small section title over a group of sources.
struct LanguageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "English, Japanese" from language codes. "12 languages" when there are many.
enum SourceLanguages {
    struct Group<Item: Identifiable>: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// Sources grouped by language: the device languages first, then by name,
    /// then sources with several languages. Sources in a group are sorted by name.
    static func sections<Item: Identifiable>(_ items: [Item], languages: (Item) -> [String],
                                             name: (Item) -> String = { "\($0.id)" }) -> [Group<Item>] {
        let multiKey = "\u{FFFF}"
        var byKey: [String: [Item]] = [:]
        for item in items {
            let codes = languages(item)
            let key = codes.count == 1 ? baseCode(codes[0]) : multiKey
            byKey[key, default: []].append(item)
        }
        let preferred = Locale.preferredLanguages.map(baseCode)
        func rank(_ key: String) -> Int {
            if key == multiKey { return Int.max }
            return preferred.firstIndex(of: key) ?? preferred.count
        }
        return byKey.keys
            .sorted { a, b in
                let (ra, rb) = (rank(a), rank(b))
                if ra != rb { return ra < rb }
                return title(for: a).localizedStandardCompare(title(for: b)) == .orderedAscending
            }
            .map { key in
                let title = key == multiKey ? String(localized: "Multiple Languages") : title(for: key)
                let sorted = byKey[key]!.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
                return Group(title: title, items: sorted)
            }
    }

    /// "zh-Hant" stays itself; "en-US" becomes "en".
    private static func baseCode(_ code: String) -> String {
        let locale = Locale(identifier: code)
        guard let language = locale.language.languageCode?.identifier else { return code }
        if let script = locale.language.script?.identifier, language == "zh" { return "zh-\(script)" }
        if code.hasPrefix("zh-TW") || code.hasPrefix("zh-HK") { return "zh-Hant" }
        if code.hasPrefix("zh-CN") || code == "zh" { return "zh-Hans" }
        if code == "pt-BR" { return code }
        return language
    }

    /// The language in its own words: "日本語", "中文", "Español".
    private static func title(for code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    static func label(_ codes: [String]) -> String {
        if codes.count > 3 { return String(localized: "\(codes.count) languages") }
        return codes.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
            .formatted(.list(type: .and, width: .narrow))
    }
}

/// Opens a manga of a source.
struct SourceMangaRoute: Hashable {
    var source: SourceInfo
    var manga: SourceManga
}

extension View {
    /// Part of libraryDestinations(), so a series from a source can open its source page.
    func sourceDestinations() -> some View {
        navigationDestination(for: SourceInfo.self) { SourceBrowseView(source: $0) }
            .navigationDestination(for: SourceMangaRoute.self) { SeriesPageView(route: $0) }
    }
}
