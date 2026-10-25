import SwiftUI
import SwiftData

/// Edit sheet for a series: title, author, cover, tags, reading mode and volume order.
/// Changes apply only on Save. Same look as the other sheets (dark gradient).
struct SeriesEditView: View {
    let series: Series

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.defaultReadingMode) private var defaultMode: ReadingMode = .rightToLeft

    @State private var title = ""
    @State private var author = ""
    @State private var tags: [String] = []
    @State private var showsTagPicker = false
    /// nil = keep the cover as it is.
    @State private var coverChoice: CoverChoice?
    @State private var showsCoverPicker = false
    @State private var mode: ReadingMode?
    @State private var volumes: [Volume] = []
    @State private var orderChanged = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    TextField("Title", text: $title)
                        .font(.body.weight(.semibold))
                    TextField("Author", text: $author, prompt: Text("Author (optional)"))
                }
                .listRowBackground(Theme.sectionFill)

                Section("Cover") {
                    HStack(spacing: 16) {
                        CoverView(title: trimmed(title).isEmpty ? series.title : trimmed(title),
                                  imageURL: coverPreviewURL, cornerRadius: 8)
                            .frame(width: 64)
                            .shadow(radius: 0)
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Choose Cover…", systemImage: "photo.on.rectangle") { showsCoverPicker = true }
                            if hasChosenCover {
                                Button("Use Default Cover", systemImage: "arrow.uturn.backward") {
                                    coverChoice = .automatic
                                }
                            }
                        }
                        // Two buttons in one row: each must take only its own taps.
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.sectionFill)

                Section {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                    }
                    .onDelete { tags.remove(atOffsets: $0) }
                    Button("Add Tags…", systemImage: "plus.circle.fill") { showsTagPicker = true }
                } header: {
                    Text("Tags")
                }
                .listRowBackground(Theme.sectionFill)

                Section("Reading Mode") {
                    Picker("Reading Mode", selection: $mode) {
                        Text("Default (\(Text(defaultMode.title)))").tag(ReadingMode?.none)
                        ForEach(ReadingMode.allCases) { item in
                            Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
                                .tag(ReadingMode?.some(item))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Theme.sectionFill)

                Section {
                    ForEach(volumes) { volume in
                        HStack(spacing: 12) {
                            CoverView(title: volume.displayName, imageURL: volume.coverURL, cornerRadius: 6)
                                .frame(width: 32)
                                .shadow(radius: 0)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(volume.displayName)
                                Text("\(volume.pageCount) pages")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    .onMove { from, to in
                        volumes.move(fromOffsets: from, toOffset: to)
                        orderChanged = true
                    }
                    Button("Sort by Volume Number", systemImage: "arrow.up.arrow.down") {
                        volumes.sort { Self.numberOrder($0, $1) }
                        orderChanged = true
                    }
                } header: {
                    Text("Volume Order")
                } footer: {
                    Text("Drag to change the reading order.")
                }
                .listRowBackground(Theme.sectionFill)
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .navigationTitle("Edit Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm, action: save)
                        .disabled(trimmed(title).isEmpty)
                }
            }
        }
        .presentationBackground(Theme.sheetGradient)
        .onAppear(perform: load)
        .sheet(isPresented: $showsTagPicker) { TagPickerView(selection: $tags) }
        .sheet(isPresented: $showsCoverPicker) {
            CoverPickerView(series: series, onChoose: { coverChoice = $0 }, canUseDefault: hasChosenCover)
        }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        title = series.title
        author = series.author ?? ""
        tags = series.sortedTagNames
        mode = series.readingMode
        volumes = series.sortedVolumes
    }

    /// The cover as it will be after Save.
    private var coverPreviewURL: URL? {
        switch coverChoice {
        case .page(let url): url
        case .automatic: volumes.first?.coverURL
        case nil: series.coverURL
        }
    }

    private var hasChosenCover: Bool {
        switch coverChoice {
        case .page: true
        case .automatic: false
        case nil: series.customCoverFile != nil
        }
    }

    private func save() {
        series.title = trimmed(title)
        series.author = trimmed(author).isEmpty ? nil : trimmed(author)
        series.readingMode = mode
        SeriesActions.setTags(tags, on: series, in: context)
        if orderChanged {
            // "Sort by Volume Number" with no drag afterwards clears the hand-made order.
            let byNumber = volumes.map(\.id) == series.sortedVolumes.sorted { Self.numberOrder($0, $1) }.map(\.id)
            for (index, volume) in volumes.enumerated() {
                volume.sortIndex = byNumber ? nil : index
            }
        }
        try? context.save()
        switch coverChoice {
        case .page(let url):
            let series = series
            Task { await SeriesCover.use(page: url, for: series) }
        case .automatic: SeriesCover.reset(series)
        case nil: break
        }
        dismiss()
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The order without the user's hand-made order: by number, then by name.
    private static func numberOrder(_ a: Volume, _ b: Volume) -> Bool {
        switch (a.number, b.number) {
        case let (x?, y?) where x != y: x < y
        case (.some, .none): true
        case (.none, .some): false
        default: a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// Navigation value for "other series by this author".
struct AuthorRoute: Hashable {
    let name: String
}

/// Navigation value for "all series with this tag".
struct TagRoute: Hashable {
    let name: String
}

/// All series by an author. Series with several authors ("A, B") match each name.
struct AuthorSeriesView: View {
    let route: AuthorRoute

    var body: some View {
        let names = Set(route.name.split(separator: ",").map {
            TitleNormalizer.key($0.trimmingCharacters(in: .whitespaces))
        })
        FilteredSeriesView(title: route.name) { series in
            series.authorNames.contains { names.contains(TitleNormalizer.key($0)) }
        }
    }
}

/// All series with a tag. Tag names match like titles (case and width do not matter).
struct TagSeriesView: View {
    let route: TagRoute

    var body: some View {
        let key = TitleNormalizer.key(route.name)
        FilteredSeriesView(title: route.name) { series in
            (series.tags ?? []).contains { TitleNormalizer.key($0.name) == key }
        }
    }
}

/// A series grid with a title, for the author and tag pages.
private struct FilteredSeriesView: View {
    let title: String
    let matches: (Series) -> Bool

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Series.title) private var allSeries: [Series]
    @State private var seriesToDelete: Series?

    var body: some View {
        ScrollView {
            SeriesGrid(series: allSeries.filter(matches), isWide: sizeClass == .regular) { seriesToDelete = $0 }
                .padding(.horizontal, sizeClass == .regular ? 40 : 16)
                .padding(.vertical, 8)
        }
        .background(ScreenBackground())
        .navigationTitle(title)
        .confirmationDialog("Delete Series?", isPresented: deleteBinding, presenting: seriesToDelete) { series in
            Button("Delete Series", role: .destructive) { LibraryActions.delete(series, in: context) }
        } message: { series in
            Text("This removes \(series.volumeCount) volumes and their pages from this device.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { seriesToDelete != nil }, set: { if !$0 { seriesToDelete = nil } })
    }
}

extension View {
    /// The pages a library navigation stack can push: a series, an author and a tag.
    func libraryDestinations() -> some View {
        navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            .navigationDestination(for: AuthorRoute.self) { AuthorSeriesView(route: $0) }
            .navigationDestination(for: TagRoute.self) { TagSeriesView(route: $0) }
    }
}
