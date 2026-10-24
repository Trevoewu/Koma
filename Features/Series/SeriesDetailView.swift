import SwiftUI
import SwiftData

/// The series page (the Series board): background tinted with the cover color,
/// centered cover, title, author (tap → other series by this author), tags with
/// a dashed "+ Tag" chip (tap a tag → all series with it), "8 volumes · 1412 pages · Right to Left", one white
/// Continue button, and the volume grid (finished = dimmed + check, current = progress bar).
struct SeriesDetailView: View {
    let series: Series

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(SettingsKey.defaultReadingMode) private var defaultMode: ReadingMode = .rightToLeft

    @State private var tint = SeriesTint.neutral
    /// Settings → Detect Webtoons, checked on the volume that Continue opens.
    @State private var isWebtoon = false
    @State private var readingVolume: Volume?
    @State private var showsEdit = false
    @State private var showsAddTag = false
    @State private var newTag = ""
    @State private var confirmsDeleteSeries = false
    @State private var volumeToDelete: Volume?
    /// Set while the page closes after a delete, so nothing reads the deleted models.
    @State private var isDeleted = false

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isDeleted {
                Color.clear
            } else {
                content
            }
        }
        .background(SeriesBackground(tint: tint))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !isDeleted { toolbar } }
        .task { SeriesActions.extractFilenameTags(for: series, in: context) }
        .task(id: series.coverURL) { tint = await SeriesTint.load(for: series) }
        .task(id: detectionVolume?.id) {
            guard series.readingMode == nil, let volume = detectionVolume else { return }
            isWebtoon = await WebtoonDetector.isWebtoon(volume)
        }
        .sheet(isPresented: $showsEdit) { SeriesEditView(series: series) }
        .fullScreenCover(item: $readingVolume) { ReaderView(volume: $0) }
        .alert("Add Tag", isPresented: $showsAddTag) {
            TextField("Tag Name", text: $newTag)
            Button("Add") {
                SeriesActions.addTag(newTag, to: series, in: context)
                newTag = ""
            }
            Button("Cancel", role: .cancel) { newTag = "" }
        }
        .confirmationDialog("Delete “\(series.title)”?", isPresented: $confirmsDeleteSeries, titleVisibility: .visible) {
            Button("Delete Series", role: .destructive, action: deleteSeries)
        } message: {
            Text("This removes \(series.volumeCount) volumes and their pages from this device.")
        }
        .confirmationDialog("Delete \(volumeToDelete?.displayName ?? "")?", isPresented: volumeDialogBinding,
                            titleVisibility: .visible, presenting: volumeToDelete) { volume in
            Button("Delete Volume", role: .destructive) { deleteVolume(volume) }
        } message: { _ in
            Text("Its pages are removed from this device.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                CoverView(title: series.title, imageURL: series.coverURL, cornerRadius: 16)
                    .frame(width: isWide ? 180 : 140)
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 22)
                    .padding(.top, 10)

                Text(series.title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)

                if let author = series.author, !author.isEmpty {
                    NavigationLink(value: AuthorRoute(name: author)) {
                        HStack(spacing: 4) {
                            Text(author)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.bodyText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows other series by this author")
                }

                tags
                    .padding(.top, series.author == nil ? 14 : 4)

                Text(statsLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 12)

                continueButton
                    .frame(maxWidth: 520)
                    .padding(.top, 18)

                SectionHeader(title: "Volumes", systemImage: "square.grid.2x2", isWide: isWide) {
                    Text(series.volumeCount, format: .number)
                        .font(.subheadline)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 4)
                .padding(.top, 26)
                .padding(.bottom, 12)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(series.sortedVolumes) { volume in
                        Button { readingVolume = volume } label: {
                            VolumeCell(volume: volume, isCurrent: volume === currentVolume)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { volumeMenu(volume) }
                    }
                }
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, isWide ? 40 : 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var tags: some View {
        FlowLayout(spacing: 8) {
            ForEach(series.sortedTagNames, id: \.self) { name in
                NavigationLink(value: TagRoute(name: name)) {
                    // 44 pt touch target; the layout keeps the 30 pt chip.
                    TagChip(name: name)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                        .padding(.vertical, -7)
                }
                .buttonStyle(.plain)
                    .accessibilityHint("Shows all series with this tag")
            }
            AddTagChip { showsAddTag = true }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var continueButton: some View {
        if let volume = currentVolume {
            Button { readingVolume = volume } label: {
                Label(continueTitle(for: volume), systemImage: "play.fill")
            }
            .buttonStyle(.primaryFullWidth)
        } else if let first = series.sortedVolumes.first {
            Button {
                first.currentPage = 0
                readingVolume = first
            } label: {
                Label("Read Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.primaryFullWidth)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // The board shows icon and text. A toolbar turns any Label into its icon.
            Button { showsEdit = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                    Text("Edit")
                }
                .padding(.horizontal, 6)
            }
            .accessibilityLabel("Edit")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    SeriesActions.markAll(series, read: true)
                }
                Button("Mark All as Unread", systemImage: "circle") {
                    SeriesActions.markAll(series, read: false)
                }
                Divider()
                Button("Delete Series…", systemImage: "trash", role: .destructive) {
                    confirmsDeleteSeries = true
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private func volumeMenu(_ volume: Volume) -> some View {
        if volume.isFinished || volume.hasStarted {
            Button("Mark as Unread", systemImage: "circle") { SeriesActions.markUnread(volume) }
        }
        if !volume.isFinished {
            Button("Mark as Read", systemImage: "checkmark.circle") { LibraryActions.markFinished(volume) }
        }
        Button("Delete Volume…", systemImage: "trash", role: .destructive) { volumeToDelete = volume }
    }

    // MARK: Data

    /// The volume with the progress bar and the Continue button. nil = all finished.
    private var currentVolume: Volume? { series.continueVolume }

    private func continueTitle(for volume: Volume) -> String {
        volume.hasStarted
            ? String(localized: "Continue · p. \(volume.currentPage + 1)")
            : String(localized: "Start Reading")
    }

    private var detectionVolume: Volume? { currentVolume ?? series.sortedVolumes.first }

    /// "8 volumes · 1412 pages · Right to Left"
    private var statsLine: String {
        [String(localized: "\(series.volumeCount) volumes"),
         String(localized: "\(series.totalPages) pages"),
         String(localized: series.displayReadingMode(default: defaultMode, isWebtoon: isWebtoon).title)]
            .joined(separator: " · ")
    }

    private var columns: [GridItem] {
        isWide
            ? [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)]
            : Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4)
    }

    // MARK: Delete

    private var volumeDialogBinding: Binding<Bool> {
        Binding(get: { volumeToDelete != nil }, set: { if !$0 { volumeToDelete = nil } })
    }

    private func deleteVolume(_ volume: Volume) {
        if SeriesActions.delete(volume, in: context) { deleteSeries() }
    }

    /// Closes the page first, then deletes, so no view reads a deleted model.
    private func deleteSeries() {
        isDeleted = true
        dismiss()
        let series = series
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            LibraryActions.delete(series, in: context)
        }
    }
}

/// One volume in the grid: cover (dimmed with a check when finished, a progress
/// bar when it is the current one) and "Vol. 3" or "Vol. 3 · p. 42".
struct VolumeCell: View {
    let volume: Volume
    var isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(title: volume.displayName, imageURL: volume.coverURL, cornerRadius: Theme.Radius.smallCover)
                .opacity(volume.isFinished ? 0.55 : 1)
                .overlay(alignment: .topLeading) {
                    if volume.isFinished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 20, height: 20)
                            .background(Theme.primaryFill, in: .circle)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isCurrent, volume.hasStarted {
                        ReadingProgressBar(value: volume.progress, track: .black.opacity(0.5))
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
            Text(isCurrent && volume.hasStarted ? volume.shortProgressText : volume.displayName)
                .font(.caption)
                .foregroundStyle(isCurrent ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(volume.displayName))
        .accessibilityValue(Text(volume.isFinished ? String(localized: "Finished") : volume.hasStarted ? volume.progressText : ""))
        .accessibilityAddTraits(.isButton)
    }
}
