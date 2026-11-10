import SwiftUI

/// One source: its lists (chips) and search, as a cover grid.
struct SourceBrowseView: View {
    let source: SourceInfo

    @Environment(SourceManager.self) private var manager
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var listings: [SourceListing] = []
    @State private var selectedListing: SourceListing?
    @State private var query = ""
    @State private var submittedQuery = ""

    @State private var entries: [SourceManga] = []
    @State private var page = 1
    @State private var hasNextPage = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didLoadListings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if submittedQuery.isEmpty, listings.count > 1 {
                    chips
                }
                content
            }
            .padding(.horizontal, sizeClass == .regular ? 40 : 16)
            .padding(.vertical, 8)
        }
        .background(ScreenBackground())
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search \(source.name)"))
        .onSubmit(of: .search) { submittedQuery = query.trimmingCharacters(in: .whitespaces) }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty { submittedQuery = "" }
        }
        .task {
            guard !didLoadListings else { return }
            didLoadListings = true
            if let runner = try? await manager.runner(for: source.id) {
                listings = (try? await runner.listings()) ?? []
            }
            selectedListing = listings.first
            await reload()
        }
        .onChange(of: submittedQuery) { Task { await reload() } }
        .onChange(of: selectedListing) { Task { await reload() } }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(listings) { listing in
                    FilterChip(title: LocalizedStringResource(stringLiteral: listing.name),
                               isSelected: selectedListing == listing) {
                        selectedListing = listing
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 14) {
                        EmptyStateView(systemImage: "exclamationmark.triangle",
                                       title: "Could Not Load",
                                       message: LocalizedStringKey(errorMessage))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await reload() } }
                            .buttonStyle(.glass)
                    }
                } else if didLoadListings {
                    EmptyStateView(systemImage: "magnifyingglass", title: "No Results",
                                   message: "Check the spelling or try another word.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: sizeClass == .regular ? 22 : 16) {
                ForEach(entries) { manga in
                    NavigationLink(value: SourceMangaRoute(source: source, manga: manga)) {
                        SourceMangaCell(manga: manga, sourceID: source.id)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if manga.key == entries.last?.key { Task { await loadMore() } }
                    }
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
    }

    private var columns: [GridItem] {
        if sizeClass == .regular {
            [GridItem(.adaptive(minimum: 128), spacing: 18, alignment: .top)]
        } else {
            Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        }
    }

    // MARK: Loading

    private func reload() async {
        entries = []
        page = 1
        hasNextPage = false
        errorMessage = nil
        await load()
    }

    private func loadMore() async {
        guard hasNextPage, !isLoading else { return }
        page += 1
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let query = submittedQuery
        let listing = selectedListing
        let page = page
        do {
            let runner = try await manager.runner(for: source.id)
            let result: SourceMangaPage
            if query.isEmpty, let listing {
                result = try await runner.mangaList(listing: listing, page: page)
            } else {
                result = try await runner.search(query: query, page: page)
            }
            // The user may have changed the list or the query while this loaded.
            guard query == submittedQuery, listing == selectedListing else { return }
            let known = Set(entries.map(\.key))
            entries += result.entries.filter { !known.contains($0.key) }
            hasNextPage = result.hasNextPage && !result.entries.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SourceMangaCell: View {
    let manga: SourceManga
    let sourceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteCoverView(title: manga.title, url: manga.cover, sourceID: sourceID)
            Text(manga.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
    }
}
