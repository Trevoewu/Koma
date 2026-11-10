import Foundation
import SwiftData
import UIKit

/// Keeps a library series' source details on the device: the last details the
/// source sent (in `Series.sourceDetails`) and its cover (in `Series.sourceCoverFile`).
/// The series page shows them at once, also offline, then asks the source again.
@MainActor
enum SourceLibraryCache {
    static func manga(for series: Series) -> SourceManga? {
        guard let data = series.sourceDetails else { return nil }
        return try? JSONDecoder().decode(SourceManga.self, from: data)
    }

    /// Saves the details, and downloads the cover if it is new.
    static func store(_ manga: SourceManga, in series: Series, manager: SourceManager) async {
        let oldCover = Self.manga(for: series)?.cover
        guard let data = try? JSONEncoder().encode(manga) else { return }
        if data != series.sourceDetails {
            series.sourceDetails = data
            try? series.modelContext?.save()
        }
        guard let cover = manga.cover, cover != oldCover || series.sourceCoverFile == nil,
              let sourceID = series.sourceID
        else { return }
        await saveCover(cover, sourceID: sourceID, in: series, manager: manager)
    }

    private static func saveCover(_ url: String, sourceID: String, in series: Series, manager: SourceManager) async {
        guard let runner = try? await manager.runner(for: sourceID),
              let request = try? await runner.imageRequest(for: url, context: nil),
              let (data, _) = try? await URLSession.shared.data(for: request)
        else { return }
        let name = "source-\(UUID().uuidString).jpg"
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            guard let image = ImageDownsampler.downsample(data, maxPixelSize: ArchiveImporter.coverPixelSize),
                  let jpeg = image.jpegData(compressionQuality: 0.85)
            else { return false }
            try? FileManager.default.createDirectory(at: LibraryPaths.seriesCoversFolder,
                                                     withIntermediateDirectories: true)
            return (try? jpeg.write(to: LibraryPaths.seriesCoverURL(named: name), options: .atomic)) != nil
        }.value
        guard saved, !series.isDeleted else {
            try? FileManager.default.removeItem(at: LibraryPaths.seriesCoverURL(named: name))
            return
        }
        if let old = series.sourceCoverFile {
            try? FileManager.default.removeItem(at: LibraryPaths.seriesCoverURL(named: old))
        }
        series.sourceCoverFile = name
        try? series.modelContext?.save()
    }
}
