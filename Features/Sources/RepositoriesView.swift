import SwiftUI

/// The sources sheet: add a repository by address, then get sources from it.
///
/// Koma does not supply or recommend repositories. The user types the address.
struct RepositoriesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var manager
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .dark

    @State private var address = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var repositoryToRemove: SourceRepository?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    addSection
                    ForEach(manager.repositories) { repository in
                        repositorySection(repository)
                    }
                }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await manager.refreshIndexes() }
        }
        .presentationBackground(Theme.sheetGradient)
        .preferredColorScheme(appearance.colorScheme)
        .task { await manager.refreshIndexes() }
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

    // MARK: Sections

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Repository")
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                TextField("Repository address", text: $address, prompt: Text(verbatim: "https://"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(add)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.sectionFill, in: .capsule)
                Button(action: add) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Text("Add")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
            Text("Koma does not provide sources. Add only repositories you trust, and read only manga you are allowed to use.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
        .sectionCard()
    }

    private func repositorySection(_ repository: SourceRepository) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.name)
                        .font(.system(size: 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(repository.url.host() ?? repository.url.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                Button("Remove Repository", systemImage: "trash", role: .destructive) {
                    repositoryToRemove = repository
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
            }
            if let sources = manager.indexes[repository.url] {
                if sources.isEmpty {
                    Text("This repository has no sources.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                LazyVStack(spacing: 8) {
                    ForEach(SourceLanguages.sections(sources, languages: { $0.languages ?? [] }, name: \.name)) { section in
                        Section {
                            ForEach(section.items) { source in
                                RepositorySourceRow(source: source, repository: repository) { message in
                                    errorMessage = message
                                }
                            }
                        } header: {
                            LanguageHeader(title: section.title)
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .sectionCard()
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

struct RepositorySourceRow: View {
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
                // The section header names a single language.
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
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.sectionFill, in: .rect(cornerRadius: Theme.Radius.row))
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
