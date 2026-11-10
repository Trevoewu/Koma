import Foundation
import Observation
import SwiftData

/// Chapter downloads from sources. Downloaded chapters become volumes in the
/// library, so the library, the reader and History use them like imported files.
@MainActor
@Observable
final class SourceDownloads {
    struct Key: Hashable {
        var sourceID: String
        var mangaKey: String
        var chapterKey: String
    }

    /// 0...1 for each chapter that is downloading.
    private(set) var progress: [Key: Double] = [:]
    private(set) var lastError: String?

    /// Tasks return the model id: a Volume itself cannot leave the main actor.
    @ObservationIgnored private var tasks: [Key: Task<PersistentIdentifier?, Never>] = [:]

    func isDownloading(_ key: Key) -> Bool { progress[key] != nil }

    func clearError() { lastError = nil }

    /// The library volume for a chapter, if it is downloaded.
    static func volume(for key: Key, in context: ModelContext) -> Volume? {
        let chapterKey = key.chapterKey
        let descriptor = FetchDescriptor<Volume>(predicate: #Predicate { $0.sourceChapterKey == chapterKey })
        return (try? context.fetch(descriptor))?.first {
            $0.series?.sourceID == key.sourceID && $0.series?.sourceMangaKey == key.mangaKey
        }
    }

    /// The downloaded chapters of a manga, by chapter key. One fetch for all chapters.
    static func downloadedVolumes(sourceID: String, mangaKey: String, in context: ModelContext) -> [String: Volume] {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate {
            $0.sourceID == sourceID && $0.sourceMangaKey == mangaKey
        })
        let series = (try? context.fetch(descriptor)) ?? []
        var volumes: [String: Volume] = [:]
        for volume in series.flatMap({ $0.volumes ?? [] }) where !volume.isDeleted {
            if let key = volume.sourceChapterKey { volumes[key] = volume }
        }
        return volumes
    }

    /// Downloads a chapter (or finds it in the library) and returns its volume.
    @discardableResult
    func download(_ chapter: SourceChapter, of manga: SourceManga, source: SourceInfo,
                  manager: SourceManager, context: ModelContext) async -> Volume? {
        let key = Key(sourceID: source.id, mangaKey: manga.key, chapterKey: chapter.key)
        if let volume = Self.volume(for: key, in: context) { return volume }
        if let task = tasks[key] { return await task.value.flatMap { context.model(for: $0) as? Volume } }

        progress[key] = 0
        let task = Task<PersistentIdentifier?, Never> { [weak self] in
            defer {
                self?.progress[key] = nil
                self?.tasks[key] = nil
            }
            do {
                let runner = try await manager.runner(for: source.id)
                let imported = try await ChapterDownloader.download(runner: runner, manga: manga, chapter: chapter) { value in
                    Task { @MainActor in
                        if self?.progress[key] != nil { self?.progress[key] = value }
                    }
                }
                let volume = try Self.link(imported, key: key, viewer: manga.viewer, context: context)
                if let series = volume.series {
                    // Not awaited: the reader must not wait for the cover download.
                    Task { await SourceLibraryCache.store(manga, in: series, manager: manager) }
                }
                return volume.persistentModelID
            } catch is CancellationError {
                return nil
            } catch {
                self?.lastError = error.localizedDescription
                return nil
            }
        }
        tasks[key] = task
        return await task.value.flatMap { context.model(for: $0) as? Volume }
    }

    func cancel(_ key: Key) {
        tasks[key]?.cancel()
    }

    private static func link(_ imported: ImportedVolume, key: Key, viewer: SourceViewer,
                             context: ModelContext) throws -> Volume {
        do {
            var linker = try LibraryLinker(context: context, sourceID: key.sourceID, mangaKey: key.mangaKey)
            let volume = try linker.add(imported)
            volume.sourceChapterKey = key.chapterKey
            if let series = volume.series {
                series.sourceID = key.sourceID
                series.sourceMangaKey = key.mangaKey
                if series.readingMode == nil {
                    switch viewer {
                    case .rightToLeft: series.readingMode = .rightToLeft
                    case .leftToRight: series.readingMode = .leftToRight
                    case .vertical, .webtoon: series.readingMode = .vertical
                    case .unknown: break
                    }
                }
            }
            try context.save()
            return volume
        } catch {
            try? LibraryPaths.deleteFiles(for: imported.id)
            throw error
        }
    }
}
