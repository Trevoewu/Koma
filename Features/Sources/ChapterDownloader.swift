import Foundation
import UIKit
import ZIPFoundation

/// Downloads the pages of one chapter into the library folder, like an import.
/// The result is an ImportedVolume, so the main actor links it with LibraryLinker.
nonisolated enum ChapterDownloader {
    /// Pages that download at the same time.
    static let parallelPages = 4

    /// @concurrent: runs off the main actor even when the caller is on it.
    @concurrent
    static func download(runner: SourceRunner, manga: SourceManga, chapter: SourceChapter,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedVolume {
        let id = UUID()
        do {
            return try await download(into: id, runner: runner, manga: manga, chapter: chapter, progress: progress)
        } catch {
            try? LibraryPaths.deleteFiles(for: id)
            throw error
        }
    }

    @concurrent
    private static func download(into id: UUID, runner: SourceRunner, manga: SourceManga, chapter: SourceChapter,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedVolume {
        let pages = try await runner.pages(manga: manga, chapter: chapter)
        guard !pages.isEmpty else { throw ImportError.noImages }

        let folder = LibraryPaths.pagesFolder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var files = [String?](repeating: nil, count: pages.count)
        var sizes = [Int64](repeating: 0, count: pages.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, String, Int64).self) { group in
            var next = 0
            func addNext() {
                guard next < pages.count else { return }
                let index = next
                next += 1
                group.addTask {
                    let (data, ext) = try await pageData(pages[index], runner: runner)
                    let name = String(format: "%04d", index + 1) + "." + ext
                    try data.write(to: folder.appending(path: name), options: .atomic)
                    return (index, name, Int64(data.count))
                }
            }
            for _ in 0..<parallelPages { addNext() }
            for try await (index, name, size) in group {
                files[index] = name
                sizes[index] = size
                done += 1
                // Whole percents only, so the screen redraws at most 100 times.
                if done * 100 / pages.count != (done - 1) * 100 / pages.count {
                    progress(Double(done) / Double(pages.count))
                }
                addNext()
            }
        }

        let pageFiles = files.compactMap { $0 }
        if let first = pageFiles.first {
            makeCover(from: folder.appending(path: first), to: LibraryPaths.coverURL(for: id))
        }

        return ImportedVolume(
            id: id,
            volumeTitle: chapter.displayTitle,
            seriesTitle: manga.title,
            number: chapter.chapterNumber.map(Double.init) ?? chapter.volumeNumber.map(Double.init),
            pageFiles: pageFiles,
            fileSize: sizes.reduce(0, +),
            author: manga.creatorLine,
            summary: manga.summary.nonEmpty,
            tags: manga.tags ?? [],
            isRightToLeft: manga.viewer == .rightToLeft
        )
    }

    /// The bytes and file extension of one page.
    private static func pageData(_ page: ResolvedPage, runner: SourceRunner) async throws -> (Data, String) {
        switch page {
        case let .data(data, ext):
            return (data, ext)
        case let .url(url, context):
            let request = try await runner.imageRequest(for: url, context: context)
            let (data, response) = try await fetch(request)
            let page = try await runner.processPageImage(data, response: response, request: request, context: context) ?? data
            guard ChapterFile.isImage(page) else { throw ImportError.damaged }
            return (page, ChapterFile.fileExtension(for: page))
        case let .zip(url, path):
            let request = try await runner.imageRequest(for: url, context: nil)
            let (data, _) = try await fetch(request)
            let page = try extract(path, fromZip: data)
            return (page, ChapterFile.fileExtension(for: page))
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(attempt)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                guard (200..<300).contains(http?.statusCode ?? 200), !data.isEmpty else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                return (data, http)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private static func extract(_ path: String, fromZip data: Data) throws -> Data {
        let archive = try Archive(data: data, accessMode: .read)
        guard let entry = archive[path] else { throw ImportError.noImages }
        var page = Data()
        _ = try archive.extract(entry) { page.append($0) }
        return page
    }

    private static func makeCover(from page: URL, to cover: URL) {
        guard let image = ImageDownsampler.downsample(page, maxPixelSize: ArchiveImporter.coverPixelSize),
              let data = image.jpegData(compressionQuality: 0.8)
        else { return }
        try? data.write(to: cover, options: .atomic)
    }
}
