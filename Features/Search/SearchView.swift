import SwiftUI
import SwiftData

/// The search tab (Tab role .search): finds series by title, author or tag.
struct SearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Series.title) private var allSeries: [Series]

    @State private var query = ""
    @State private var seriesToDelete: Series?

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass",
                                   title: "Search Your Library",
                                   message: "Find a series by title, author or tag.")
                } else if results.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass",
                                   title: "No Results",
                                   message: "Check the spelling or try another word.")
                } else {
                    ScrollView {
                        SeriesGrid(series: results, isWide: sizeClass == .regular) { seriesToDelete = $0 }
                            .padding(.horizontal, sizeClass == .regular ? 40 : 16)
                            .padding(.vertical, 8)
                    }
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Search")
            .libraryDestinations()
        }
        .searchable(text: $query, prompt: "Titles, authors, tags")
        .confirmationDialog("Delete Series?", isPresented: deleteDialogBinding, presenting: seriesToDelete) { series in
            Button("Delete Series", role: .destructive) { LibraryActions.delete(series, in: context) }
        } message: { series in
            Text("This removes \(series.volumeCount) volumes and their pages from this device.")
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [Series] {
        let text = trimmedQuery
        return allSeries.filter { series in
            series.title.localizedStandardContains(text)
                || (series.author?.localizedStandardContains(text) ?? false)
                || series.sortedTagNames.contains { $0.localizedStandardContains(text) }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { seriesToDelete != nil }, set: { if !$0 { seriesToDelete = nil } })
    }
}
