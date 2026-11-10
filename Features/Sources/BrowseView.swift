import SwiftUI

/// The Browse tab: the installed sources. Tap a source to browse and search it.
/// Koma comes with no sources. The user adds a repository address in the sheet.
struct BrowseView: View {
    @Environment(SourceManager.self) private var manager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsRepositories = false
    @State private var sourceToRemove: SourceInfo?

    var body: some View {
        NavigationStack {
            Group {
                if manager.installed.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(SourceLanguages.sections(manager.installed, languages: manager.readingLanguages, name: \.name)) { section in
                                Section {
                                    ForEach(section.items) { source in
                                        NavigationLink(value: source) {
                                            InstalledSourceRow(source: source)
                                        }
                                        .buttonStyle(.plain)
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
                        .padding(.horizontal, sizeClass == .regular ? 40 : 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sources", systemImage: "plus") { showsRepositories = true }
                        .badge(manager.updates.count)
                }
            }
            .libraryDestinations()
        }
        .sheet(isPresented: $showsRepositories) { RepositoriesView() }
        .task { await manager.refreshIndexes() }
        .confirmationDialog("Remove Source?", isPresented: removeDialogBinding, presenting: sourceToRemove) { source in
            Button("Remove \(source.name)", role: .destructive) { manager.uninstall(source.id) }
        } message: { _ in
            Text("Chapters you downloaded stay in your library.")
        }
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

    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 320), spacing: 14)]
            : [GridItem(.flexible())]
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
            SourceIcon(url: manager.iconURL(for: source.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body.weight(.semibold))
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
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.sectionFill, in: .rect(cornerRadius: Theme.Radius.row))
        .contentShape(.rect(cornerRadius: Theme.Radius.row))
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.leading, 4)
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

    private static func title(for code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
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
