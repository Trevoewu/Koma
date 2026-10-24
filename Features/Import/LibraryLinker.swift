import Foundation
import SwiftData

/// Creates the SwiftData models for imported volumes, on the main actor.
///
/// It puts each volume into an existing series with the same normalized title,
/// or makes a new series. It reuses tags with the same name.
/// Make one linker per import batch: it caches series and tags, so volumes
/// from the same batch also find each other.
struct LibraryLinker {
    let context: ModelContext
    private var seriesByKey: [String: Series]
    private var tagsByKey: [String: Tag]

    init(context: ModelContext) throws {
        self.context = context
        let allSeries = try context.fetch(FetchDescriptor<Series>(sortBy: [SortDescriptor(\.dateAdded)]))
        seriesByKey = Dictionary(allSeries.map { (TitleNormalizer.key($0.title), $0) },
                                 uniquingKeysWith: { first, _ in first })
        let allTags = try context.fetch(FetchDescriptor<Tag>())
        tagsByKey = Dictionary(allTags.map { (TitleNormalizer.key($0.name), $0) },
                               uniquingKeysWith: { first, _ in first })
    }

    /// Inserts and saves. If the save fails, the changes are rolled back and the
    /// error is thrown; the caller deletes the volume's files.
    @discardableResult
    mutating func add(_ imported: ImportedVolume) throws -> Volume {
        let series = series(titled: imported.seriesTitle)

        // ComicInfo fills only empty fields. It never overwrites the user's edits.
        if series.author == nil { series.author = imported.author }
        if series.summary == nil { series.summary = imported.summary }
        if imported.isRightToLeft, series.readingMode == nil { series.readingMode = .rightToLeft }

        var tags = series.tags ?? []
        for name in imported.tags {
            let tag = tag(named: name)
            if !tags.contains(where: { $0 === tag }) { tags.append(tag) }
        }
        series.tags = tags

        let volume = Volume(title: imported.volumeTitle, number: imported.number,
                            pageFiles: imported.pageFiles, fileSize: imported.fileSize)
        volume.id = imported.id   // Must match the folder on disk.
        // A series the user ordered by hand gets new volumes at the end.
        if let last = (series.volumes ?? []).compactMap(\.sortIndex).max() {
            volume.sortIndex = last + 1
        }
        context.insert(volume)
        volume.series = series

        do {
            try context.save()
        } catch {
            context.rollback()
            // Rollback can leave our cache pointing at discarded models.
            seriesByKey = seriesByKey.filter { !$0.value.isDeleted && $0.value.modelContext != nil }
            tagsByKey = tagsByKey.filter { !$0.value.isDeleted && $0.value.modelContext != nil }
            throw error
        }
        return volume
    }

    private mutating func series(titled title: String) -> Series {
        let key = TitleNormalizer.key(title)
        if let existing = seriesByKey[key] { return existing }
        let series = Series(title: title)
        context.insert(series)
        seriesByKey[key] = series
        return series
    }

    private mutating func tag(named name: String) -> Tag {
        let key = TitleNormalizer.key(name)
        if let existing = tagsByKey[key] { return existing }
        let tag = Tag(name: name)
        context.insert(tag)
        tagsByKey[key] = tag
        return tag
    }
}
