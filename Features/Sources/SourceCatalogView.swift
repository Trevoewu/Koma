import SwiftUI

/// The sources sheet: one flat list of the sources in all repositories, with
/// search and language chips. Repositories are managed on their own screen.
///
/// Koma does not supply or recommend repositories. The user types the address.
struct SourceCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var manager
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .dark
    @AppStorage(SettingsKey.showAdultSources) private var showsAdult = false

    @State private var query = ""
    /// The selected language chip (a group title). nil = all languages.
    @State private var language: String?
    @State private var didChooseLanguage = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sources")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search sources")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            RepositoryListView()
                        } label: {
                            Label("Repositories", systemImage: "list.bullet")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationBackground(Theme.sheetGradient)
        .preferredColorScheme(appearance.colorScheme)
        .task { await manager.refreshIndexes() }
        // The list may be cached (on appear) or arrive later (on change).
        .onAppear { chooseDefaultLanguage(allGroups.map(\.title)) }
        .onChange(of: allGroups.map(\.title)) { _, titles in chooseDefaultLanguage(titles) }
        .alert("Could Not Add Source", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if manager.repositories.isEmpty {
            VStack(spacing: 18) {
                EmptyStateView(systemImage: "puzzlepiece.extension", title: "No Repositories",
                               message: "Add a repository address to see its sources.")
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    RepositoryListView()
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty, isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if visibleGroups.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "No Results",
                                   message: "Check the spelling or try another word.")
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.items) { entry in
                            SourceCatalogRow(source: entry.source, repository: entry.repository) { errorMessage = $0 }
                                .listRowBackground(Theme.cardFill)
                        }
                    } header: {
                        // The chips live in the first header: a bar pinned over the list
                        // did not draw when the sheet opened again, and a row clips them.
                        VStack(alignment: .leading, spacing: 14) {
                            if showsChips, group.id == visibleGroups.first?.id {
                                languageChips.textCase(nil)
                            }
                            if showsHeaders {
                                LanguageHeader(title: group.title).padding(.leading, 16)
                            }
                        }
                        // No header inset: the chips start at the card edge.
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, Theme.Size.listMargin, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await manager.refreshIndexes() }
        }
    }

    private var languageChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: language == nil) { language = nil }
                ForEach(allGroups) { group in
                    FilterChip(title: LocalizedStringResource(stringLiteral: group.title),
                               isSelected: language == group.title) { language = group.title }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        // Chips scroll past the list margin; glass needs room to draw.
        .scrollClipDisabled()
    }

    // MARK: Data

    struct Entry: Identifiable {
        let source: RepositorySource
        let repository: SourceRepository
        var id: String { source.id }
    }

    private var isLoading: Bool {
        manager.repositories.contains { manager.indexes[$0.url] == nil }
    }

    /// The sources of all repositories. A source in two repositories shows once,
    /// in its newest version. Mainly adult sources only when Settings allows them.
    private var entries: [Entry] {
        var byID: [String: Entry] = [:]
        for repository in manager.repositories {
            for source in manager.indexes[repository.url] ?? [] where showsAdult || !source.isAdult {
                if let existing = byID[source.id], existing.source.version >= source.version { continue }
                byID[source.id] = Entry(source: source, repository: repository)
            }
        }
        return Array(byID.values)
    }

    private var allGroups: [SourceLanguages.Group<Entry>] {
        SourceLanguages.sections(entries, languages: { $0.source.languages ?? [] }, name: \.source.name)
    }

    /// A search looks in all languages. Without one, the chip picks the language.
    private var visibleGroups: [SourceLanguages.Group<Entry>] {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let matches = entries.filter {
                $0.source.name.localizedStandardContains(text) || $0.source.id.localizedStandardContains(text)
            }
            return SourceLanguages.sections(matches, languages: { $0.source.languages ?? [] }, name: \.source.name)
        }
        guard let language else { return allGroups }
        return allGroups.filter { $0.title == language }
    }

    private var showsChips: Bool { query.isEmpty && allGroups.count > 1 }

    /// With one language on screen, its header would only repeat the chip.
    private var showsHeaders: Bool { visibleGroups.count > 1 }

    /// The first group is the device language (see SourceLanguages.sections). Start there,
    /// so the list is short. Only once: the user's own choice stays.
    private func chooseDefaultLanguage(_ titles: [String]) {
        guard !didChooseLanguage, let first = titles.first else { return }
        didChooseLanguage = true
        if titles.count > 1, first != String(localized: "Multiple Languages") { language = first }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// One source: icon, name (and its languages when it has several), and Get / Update / installed.
struct SourceCatalogRow: View {
    let source: RepositorySource
    let repository: SourceRepository
    let onError: (String) -> Void

    @Environment(SourceManager.self) private var manager

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(url: source.iconURL.flatMap { URL(string: $0, relativeTo: repository.url)?.absoluteURL },
                       size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if let languages = source.languages, languages.count > 1 {
                    Text(SourceLanguages.label(languages))
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var action: some View {
        if manager.installing.contains(source.id) {
            ProgressView()
                .frame(width: 44, height: 44)
        } else if let version = manager.installedVersion(of: source.id) {
            if source.version > version {
                Button("Update") { install() }
                    .buttonStyle(.glass)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Installed")
            }
        } else {
            Button("Get") { install() }
                .buttonStyle(.glass)
        }
    }

    private func install() {
        Task {
            do {
                try await manager.install(source, from: repository)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

/// Add and remove repository addresses.
struct RepositoryListView: View {
    @Environment(SourceManager.self) private var manager

    @State private var address = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var repositoryToRemove: SourceRepository?
    @FocusState private var addressFocused: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Repository address", text: $address, prompt: Text(verbatim: "https://"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(add)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Theme.cardFill, in: .capsule)
                    Button(action: add) {
                        if isAdding { ProgressView() } else { Text("Add") }
                    }
                    .buttonStyle(.glass)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                Text("Koma does not provide sources. Add only repositories you trust, and read only manga you are allowed to use.")
                    .foregroundStyle(Theme.tertiaryText)
            }

            if !manager.repositories.isEmpty {
                Section {
                    ForEach(manager.repositories) { repository in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repository.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                            Text(repository.url.host() ?? repository.url.absoluteString)
                                .font(.footnote)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Theme.cardFill)
                        .swipeActions {
                            Button("Remove Repository", systemImage: "trash", role: .destructive) {
                                repositoryToRemove = repository
                            }
                        }
                        .contextMenu {
                            Button("Remove Repository", systemImage: "trash", role: .destructive) {
                                repositoryToRemove = repository
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, Theme.Size.listMargin, for: .scrollContent)
        .navigationTitle("Repositories")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if manager.repositories.isEmpty { addressFocused = true } }
        .alert("Could Not Add Source", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Remove Repository?", isPresented: removeDialogBinding,
                            presenting: repositoryToRemove) { repository in
            Button("Remove \(repository.name)", role: .destructive) { manager.removeRepository(repository) }
        } message: { _ in
            Text("Installed sources stay installed.")
        }
    }

    private func add() {
        let text = address
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isAdding else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                try await manager.addRepository(address: text)
                address = ""
                addressFocused = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var removeDialogBinding: Binding<Bool> {
        Binding(get: { repositoryToRemove != nil }, set: { if !$0 { repositoryToRemove = nil } })
    }
}
