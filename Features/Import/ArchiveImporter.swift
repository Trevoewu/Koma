import Foundation
import UIKit
import ZIPFoundation

/// Everything the main actor needs to create the models for one imported file.
/// The pages are already on disk in LibraryPaths.volumeFolder(for: id).
nonisolated struct ImportedVolume: Sendable {
    var id: UUID
    var volumeTitle: String
    var seriesTitle: String
    var number: Double?
    var pageFiles: [String]
    var fileSize: Int64
    var author: String?
    var summary: String?
    var tags: [String]
    var isRightToLeft: Bool
}

nonisolated enum ImportError: LocalizedError, Sendable {
    case unreadable      // not a zip, or encrypted
    case damaged         // the zip opens, but its data is broken
    case noImages
    case noSpace
    case writeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable:  String(localized: "This file is not a ZIP or CBZ archive, or it is protected with a password.")
        case .damaged:     String(localized: "The archive is damaged. Some pages could not be read.")
        case .noImages:    String(localized: "The archive has no pages (JPG, PNG, WebP, GIF, HEIC or AVIF).")
        case .noSpace:     String(localized: "There is not enough free storage on this device.")
        case .writeFailed: String(localized: "The pages could not be saved.")
        case .cancelled:   String(localized: "The import was stopped.")
        }
    }
}

/// Unzips one archive into the library folder. Runs off the main actor.
///
/// It never uses the paths from the zip to write files. Pages get our own
/// names (0001.jpg, 0002.png…), so a "../../" entry cannot escape the folder.
actor ArchiveImporter {
    static let pageExtensions: Set<String> = ["jpg", "jpeg", "png", "apng", "webp", "gif", "heic", "avif"]
    static let coverPixelSize: CGFloat = 600

    /// `progress` gets 0...1 for this file, once per page.
    /// On any error, the volume folder is deleted before the error is thrown.
    func importArchive(at url: URL, progress: @Sendable (Double) -> Void) throws(ImportError) -> ImportedVolume {
        let id = UUID()
        do {
            return try extract(url, into: id, progress: progress)
        } catch {
            try? LibraryPaths.deleteFiles(for: id)
            throw Self.importError(for: error)
        }
    }

    private func extract(_ url: URL, into id: UUID, progress: @Sendable (Double) -> Void) throws -> ImportedVolume {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ImportError.unreadable
        }

        let entries = Array(archive).filter { $0.type == .file }
        let decoder = ArchiveNameDecoder(entries: entries)
        let named = entries.map { (entry: $0, name: decoder.name(of: $0)) }

        let pages = named
            .filter { Self.isPage($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !pages.isEmpty else { throw ImportError.noImages }

        let info = comicInfo(in: named, archive: archive)

        let pagesFolder = LibraryPaths.pagesFolder(for: id)
        try FileManager.default.createDirectory(at: pagesFolder, withIntermediateDirectories: true)

        var pageFiles: [String] = []
        var fileSize: Int64 = 0
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let ext = (page.name as NSString).pathExtension.lowercased()
            let fileName = String(format: "%04d", index + 1) + "." + ext
            try autoreleasepool {
                _ = try archive.extract(page.entry, to: pagesFolder.appending(path: fileName))
            }
            pageFiles.append(fileName)
            fileSize += Int64(clamping: page.entry.uncompressedSize)
            progress(Double(index + 1) / Double(pages.count))
        }

        makeCover(from: pageFiles.prefix(3).map { pagesFolder.appending(path: $0) },
                  to: LibraryPaths.coverURL(for: id))

        let fileTitle = url.deletingPathExtension().lastPathComponent
        let parsed = FileNameParser.parse(url.lastPathComponent)
        return ImportedVolume(
            id: id,
            volumeTitle: info?.volumeTitle ?? fileTitle,
            seriesTitle: info?.seriesTitle ?? parsed.seriesTitle,
            number: info?.volumeNumber ?? parsed.number,
            pageFiles: pageFiles,
            fileSize: fileSize,
            author: info?.author,
            summary: info?.summary.nonEmpty,
            tags: (info?.tagNames ?? []) + FileNameParser.tags(in: url.lastPathComponent),
            isRightToLeft: info?.isRightToLeft ?? false
        )
    }

    // MARK: Helpers

    /// Image files only. Skips folders, hidden files and "__MACOSX/" resource forks.
    static func isPage(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let last = parts.last, !path.hasSuffix("/") else { return false }
        if parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { return false }
        return pageExtensions.contains((String(last) as NSString).pathExtension.lowercased())
    }

    /// ComicInfo.xml at the root, else the one nearest to the root
    /// (many zips have one top folder).
    private func comicInfo(in entries: [(entry: Entry, name: String)], archive: Archive) -> ComicInfo? {
        let candidates = entries.filter {
            ($0.name as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
                && !$0.name.split(separator: "/").contains("__MACOSX")
        }
        guard let best = candidates.min(by: { $0.name.count(where: { $0 == "/" }) < $1.name.count(where: { $0 == "/" }) }),
              best.entry.uncompressedSize < 1_000_000
        else { return nil }

        var data = Data()
        guard (try? archive.extract(best.entry, consumer: { data.append($0) })) != nil else { return nil }
        return ComicInfo(data: data)
    }

    /// cover.jpg from the first page that decodes. No cover is not an error:
    /// CoverView then shows the placeholder art.
    private func makeCover(from pages: [URL], to coverURL: URL) {
        for page in pages {
            guard let image = ImageDownsampler.downsample(page, maxPixelSize: Self.coverPixelSize),
                  let data = image.jpegData(compressionQuality: 0.8)
            else { continue }
            try? data.write(to: coverURL, options: .atomic)
            return
        }
    }

    private static func importError(for error: any Error) -> ImportError {
        if let error = error as? ImportError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? CocoaError {
            return error.code == .fileWriteOutOfSpace ? .noSpace : .writeFailed
        }
        if let error = error as? POSIXError {
            return error.code == .ENOSPC ? .noSpace : .writeFailed
        }
        // ZIPFoundation's archive, entry and compression errors.
        return .damaged
    }
}
