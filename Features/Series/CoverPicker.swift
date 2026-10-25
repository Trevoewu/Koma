import SwiftUI
import SwiftData

/// Sets the cover the user chose for a series (`Series.customCoverFile`).
enum SeriesCover {
    /// Pixel size of a chosen cover. Larger than an import cover (600 px):
    /// the series page shows it at up to 180 pt.
    static let pixelSize: CGFloat = 900

    /// Makes the cover from a page: downsampled, JPEG. Decodes off the main actor.
    /// Returns false if the page cannot be read.
    @discardableResult
    static func use(page url: URL, for series: Series) async -> Bool {
        let file = UUID().uuidString + ".jpg"
        let target = LibraryPaths.seriesCoverURL(named: file)
        let size = pixelSize
        let written = await Task.detached(priority: .userInitiated) {
            guard let data = ImageDownsampler.downsample(url, maxPixelSize: size)?
                .jpegData(compressionQuality: 0.85) else { return false }
            try? FileManager.default.createDirectory(at: LibraryPaths.seriesCoversFolder,
                                                     withIntermediateDirectories: true)
            return (try? data.write(to: target, options: .atomic)) != nil
        }.value
        guard written else { return false }
        removeFile(of: series)
        series.customCoverFile = file
        try? series.modelContext?.save()
        return true
    }

    /// Back to the cover of the first volume.
    static func reset(_ series: Series) {
        removeFile(of: series)
        series.customCoverFile = nil
        try? series.modelContext?.save()
    }

    private static func removeFile(of series: Series) {
        guard let file = series.customCoverFile else { return }
        try? FileManager.default.removeItem(at: LibraryPaths.seriesCoverURL(named: file))
    }
}

/// A cover picked in the Edit sheet, applied on Save.
enum CoverChoice: Equatable {
    case page(URL)
    /// The cover of the first volume.
    case automatic
}

/// "Choose Cover": the pages of one volume, shown as 2:3 covers. Tap one to use it.
/// A menu at the top switches the volume.
/// Without `onChoose` the cover is saved at once (long-press menu). With it, the
/// choice goes back to the caller, which saves it later (the Edit sheet).
struct CoverPickerView: View {
    let series: Series
    var onChoose: ((CoverChoice) -> Void)? = nil
    /// Shows "Use Default Cover". nil = when the series has a chosen cover.
    var canUseDefault: Bool? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var volumeID: UUID?
    @State private var isSaving = false

    var body: some View {
        let volumes = series.sortedVolumes
        let volume = volumes.first { $0.id == volumeID } ?? volumes.first
        NavigationStack {
            ScrollView {
                if let volume {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .top)], spacing: 14) {
                        ForEach(volume.pageFiles.indices, id: \.self) { index in
                            if let url = volume.pageURL(at: index) {
                                pageButton(url: url, number: index + 1)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Choose Cover")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                if volumes.count > 1, let volume {
                    volumeMenu(volumes, selected: volume)
                        .padding(.vertical, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if canUseDefault ?? (series.customCoverFile != nil) {
                    // At the bottom: in the top bar this long label cuts the title.
                    ToolbarItem(placement: .bottomBar) {
                        Button("Use Default Cover") {
                            if let onChoose { onChoose(.automatic) } else { SeriesCover.reset(series) }
                            dismiss()
                        }
                    }
                }
            }
            .overlay {
                if isSaving { ProgressView().controlSize(.large) }
            }
            .disabled(isSaving)
        }
    }

    private func pageButton(url: URL, number: Int) -> some View {
        Button {
            if let onChoose {
                onChoose(.page(url))
                dismiss()
                return
            }
            isSaving = true
            Task {
                await SeriesCover.use(page: url, for: series)
                isSaving = false
                dismiss()
            }
        } label: {
            VStack(spacing: 4) {
                // The same crop as a cover, so the user sees the result.
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay { DownsampledImage(url: url) { Theme.sectionFill } }
                    .clipShape(.rect(cornerRadius: 10))
                Text(number, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Page \(number)"))
    }

    private func volumeMenu(_ volumes: [Volume], selected: Volume) -> some View {
        Menu {
            Picker("Volume", selection: Binding(get: { selected.id }, set: { volumeID = $0 })) {
                ForEach(volumes) { volume in
                    Text(volume.displayName).tag(volume.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selected.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(Text(selected.displayName))
    }
}
