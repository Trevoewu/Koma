import SwiftUI
import SwiftData

/// The Library tab: large title, import and settings buttons, filter chips,
/// the "Continue" card and the "All Series" grid.
/// iPad uses the same layout with a wider card, a "Recently Read" row and more columns.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var allSeries: [Series]

    @AppStorage(SettingsKey.librarySort) private var sort: LibrarySort = .recent
    @AppStorage(SettingsKey.defaultReadingMode) private var defaultMode: ReadingMode = .rightToLeft

    @State private var filter: LibraryFilter = .all
    @State private var path: [Series] = []
    @State private var showsImporter = false
    @State private var showsSettings = false
    @State private var readingVolume: Volume?
    @State private var seriesToDelete: Series?
    /// Detect Webtoons result for the volume in the Continue card (its mode pill on iPad).
    @State private var continueIsWebtoon = false

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if allSeries.isEmpty {
                    LibraryEmptyView { showsImporter = true }
                } else {
                    library
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Library")
            .toolbar { toolbar }
            .libraryDestinations()
        }
        .importFlow(isPresented: $showsImporter)
        .task(id: continueSeries?.continueVolume?.id) {
            continueIsWebtoon = false
            guard let series = continueSeries, series.readingMode == nil,
                  let volume = series.continueVolume else { return }
            continueIsWebtoon = await WebtoonDetector.isWebtoon(volume)
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .fullScreenCover(item: $readingVolume) { ReaderView(volume: $0) }
        .confirmationDialog(deleteTitle, isPresented: deleteDialogBinding, titleVisibility: .visible,
                            presenting: seriesToDelete) { series in
            Button("Delete Series", role: .destructive) {
                LibraryActions.delete(series, in: context)
            }
        } message: { series in
            Text("This removes \(series.volumeCount) volumes and their pages from this device.")
        }
    }

    // MARK: Content

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                filterChips

                if showsContinueCard, let series = continueSeries, let volume = series.continueVolume {
                    ContinueCard(series: series, volume: volume,
                                 readingMode: series.displayReadingMode(default: defaultMode,
                                                                         isWebtoon: continueIsWebtoon),
                                 isWide: isWide,
                                 onResume: { readingVolume = volume },
                                 onShowSeries: { path.append(series) })
                        .padding(.top, isWide ? 22 : 18)
                }

                if isWide, filter == .all, !recentVolumes.isEmpty {
                    recentlyRead
                        .padding(.top, 30)
                }

                SectionHeader(title: "All Series", systemImage: "square.grid.2x2", isWide: isWide) {
                    Text(visibleSeries.count, format: .number)
                        .font(isWide ? .callout : .subheadline)
                        .foregroundStyle(Theme.tertiaryText)
                    sortMenu
                }
                .padding(.horizontal, 4)
                .padding(.top, isWide ? 30 : 26)
                .padding(.bottom, isWide ? 14 : 8)

                if visibleSeries.isEmpty {
                    Text(filter.emptyMessage)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    SeriesGrid(series: visibleSeries, isWide: isWide) { seriesToDelete = $0 }
                }
            }
            .padding(.horizontal, isWide ? 40 : 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    FilterChip(title: item.title,
                               isSelected: filter == item) {
                        withAnimation(.snappy) { filter = item }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var recentlyRead: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Recently Read", systemImage: "clock.arrow.circlepath", isWide: true)
                .padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
                ForEach(recentVolumes) { volume in
                    RecentlyReadCard(volume: volume) { readingVolume = volume }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySort.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Sort")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The first-launch screen has its own Import Files button, so only the gear shows there.
        if !allSeries.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import", systemImage: "plus") { showsImporter = true }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showsSettings = true }
        }
    }

    // MARK: Data

    private var visibleSeries: [Series] {
        allSeries.filter(filter.matches).sorted(by: sort.areInIncreasingOrder)
    }

    private var continueSeries: Series? { Series.continueCandidate(in: allSeries) }

    private var showsContinueCard: Bool { filter == .all || filter == .reading }

    /// iPad "Recently Read": the next three series after the one in the Continue card.
    private var recentVolumes: [Volume] {
        let hero = continueSeries
        return allSeries
            .filter { $0.lastReadAt != nil && $0 !== hero }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            .compactMap(\.continueVolume)
            .prefix(3)
            .map { $0 }
    }

    // MARK: Delete

    private var deleteTitle: Text {
        Text("Delete “\(seriesToDelete?.title ?? "")”?")
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { seriesToDelete != nil }, set: { if !$0 { seriesToDelete = nil } })
    }
}

#if DEBUG
#Preview("Library") {
    LibraryView()
        .modelContainer(SampleData.makeContainer())
        .environment(ImportController())
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    LibraryView()
        .modelContainer(for: [Series.self, Volume.self, Tag.self], inMemory: true)
        .environment(ImportController())
        .preferredColorScheme(.dark)
}
#endif
