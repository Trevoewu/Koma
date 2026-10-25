import SwiftUI
import UIKit
import ZIPFoundation

/// Share a series as CBZ files, one per volume.
///
/// Koma keeps only the extracted pages, so each CBZ is rebuilt from them, with a
/// ComicInfo.xml that brings the title, number, author, tags and reading direction
/// back on import. A file is written only when the share target asks for it
/// (`CBZItemProvider`), in a temporary folder that is deleted when sharing ends.
enum SeriesShare {
    /// Plain values for one volume, so the export can run off the main actor.
    nonisolated struct Item: Sendable {
        var fileName: String
        var pageURLs: [URL]
        var comicInfo: Data
    }

    /// One share sheet: its files and the folder they go into.
    struct Request: Identifiable {
        let id: UUID
        let providers: [CBZItemProvider]
        var folder: URL { SeriesShare.folder(for: id) }
    }

    static func request(for series: Series) -> Request {
        let id = UUID()
        var usedNames = Set<String>()
        let items = series.sortedVolumes.map { volume in
            Item(fileName: uniqueName(fileName(for: volume, in: series), in: &usedNames),
                 pageURLs: volume.pageFiles.indices.compactMap { volume.pageURL(at: $0) },
                 comicInfo: comicInfo(for: volume, in: series))
        }
        let folder = folder(for: id)
        return Request(id: id, providers: items.map { CBZItemProvider(item: $0, folder: folder) })
    }

    nonisolated static func folder(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Share/\(id.uuidString)", directoryHint: .isDirectory)
    }

    /// Writes the pages as 0001.jpg… without recompression (they are already
    /// compressed images), then ComicInfo.xml.
    nonisolated static func writeCBZ(_ item: Item, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: item.fileName)
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for (index, page) in item.pageURLs.enumerated() {
            let name = String(format: "%04d", index + 1) + "." + page.pathExtension
            try autoreleasepool {
                try archive.addEntry(with: name, fileURL: page, compressionMethod: .none)
            }
        }
        let info = item.comicInfo
        try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(info.count),
                             compressionMethod: .deflate) { position, size in
            info.subdata(in: Int(position)..<Int(position) + size)
        }
        return url
    }

    // MARK: Names and metadata

    /// "Tidewater Saints Vol. 3.cbz". Without a number: the volume title, or the
    /// series title when the volume title only repeats it (a long EPUB title).
    private static func fileName(for volume: Volume, in series: Series) -> String {
        let base = if let number = volume.number {
            "\(series.title) Vol. \(plainNumber(number))"
        } else {
            volume.nameBesideSeries() == nil ? series.title : volume.title
        }
        let safe = base.replacing(#/[\/:\\\n]/#, with: "-").trimmingCharacters(in: .whitespaces)
        return (safe.isEmpty ? "Volume" : safe) + ".cbz"
    }

    private static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = (name as NSString).deletingPathExtension + " (\(counter)).cbz"
            counter += 1
        }
        return candidate
    }

    /// "3", "12.5": no grouping, always a dot.
    private static func plainNumber(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The fields the importer reads (see ComicInfo).
    private static func comicInfo(for volume: Volume, in series: Series) -> Data {
        var fields: [(String, String)] = [("Series", series.title), ("Title", volume.title)]
        if let number = volume.number { fields.append(("Number", plainNumber(number))) }
        if let author = series.author, !author.isEmpty { fields.append(("Writer", author)) }
        let tags = series.sortedTagNames
        if !tags.isEmpty { fields.append(("Tags", tags.joined(separator: ", "))) }
        if let summary = series.summary, !summary.isEmpty { fields.append(("Summary", summary)) }
        if series.readingMode == .rightToLeft { fields.append(("Manga", "YesAndRightToLeft")) }

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ComicInfo>\n"
        for (name, value) in fields {
            xml += "  <\(name)>\(escaped(value))</\(name)>\n"
        }
        xml += "</ComicInfo>\n"
        return Data(xml.utf8)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Gives the share sheet one CBZ file. The file is written on a background
/// thread when a target asks for it, so the sheet opens at once.
nonisolated final class CBZItemProvider: UIActivityItemProvider, @unchecked Sendable {
    private let export: SeriesShare.Item
    private let folder: URL

    init(item: SeriesShare.Item, folder: URL) {
        export = item
        self.folder = folder
        super.init(placeholderItem: folder.appending(path: item.fileName))
    }

    override var item: Any {
        (try? SeriesShare.writeCBZ(export, in: folder)) ?? placeholderItem as Any
    }

    override func activityViewController(_ activityViewController: UIActivityViewController,
                                         dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        "app.koma.cbz"  // UTType.cbz, which is main-actor state
    }
}

extension View {
    /// Shows the share sheet for a request, and deletes its files when it closes.
    func seriesShareSheet(_ request: Binding<SeriesShare.Request?>) -> some View {
        sheet(item: request) { shown in
            ShareSheet(items: shown.providers) { request.wrappedValue = nil }
                .presentationDetents([.medium, .large])
                .onDisappear { try? FileManager.default.removeItem(at: shown.folder) }
        }
    }
}

/// The system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
