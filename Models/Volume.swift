import Foundation
import SwiftData

/// One imported file (.zip / .cbz). Its pages are stored on disk in
/// <library root>/<id>/pages/, and its cover in <library root>/<id>/cover.jpg.
@Model
final class Volume {
    var id: UUID = UUID()

    /// File name without the extension, for example "Tidewater Saints v03".
    var title: String = ""

    /// Number found in the file name ("Vol. 03" → 3, "Ch. 12.5" → 12.5). nil if none.
    var number: Double?

    /// Page file names in reading order: ["0001.jpg", "0002.png", ...].
    var pageFiles: [String] = []

    /// 0-based index of the last page the user saw.
    var currentPage: Int = 0

    /// Position set by the user in Edit (drag to reorder). nil = order by number.
    var sortIndex: Int?

    /// 0-based pages the user bookmarked in the reader, sorted.
    /// (A list of all bookmarks is a later feature.)
    var bookmarkedPages: [Int] = []

    /// Tracks the one-time extraction for volumes imported before filename tags existed.
    var filenameTagsExtracted: Bool = false

    var isFinished: Bool = false
    var dateAdded: Date = Date.now
    var lastReadAt: Date?

    /// Size of the extracted pages on disk, in bytes.
    var fileSize: Int64 = 0

    /// The chapter key in the series' source, for a chapter downloaded from a source.
    var sourceChapterKey: String?

    var series: Series?

    init(title: String, number: Double? = nil, pageFiles: [String] = [], fileSize: Int64 = 0) {
        self.title = title
        self.number = number
        self.pageFiles = pageFiles
        self.fileSize = fileSize
    }
}

extension Volume {
    var pageCount: Int { pageFiles.count }

    var hasStarted: Bool { lastReadAt != nil }

    /// 0...1
    var progress: Double {
        if isFinished { return 1 }
        guard pageCount > 0 else { return 0 }
        return Double(currentPage + 1) / Double(pageCount)
    }

    /// "Volume 3" (reader title bar), or the file title if no number was found.
    var longDisplayName: String {
        if let number, sourceChapterKey != nil { return String(localized: "Chapter \(number.formatted(.number.grouping(.never)))") }
        if let number { return String(localized: "Volume \(number.formatted())") }
        return title
    }

    /// "Vol. 3", or the file title if no number was found.
    var displayName: String {
        if let number, sourceChapterKey != nil { return String(localized: "Ch. \(number.formatted(.number.grouping(.never)))") }
        if let number { return String(localized: "Vol. \(number.formatted())") }
        return title
    }

    /// The name to show under or after the series title, without repeating it:
    /// "Vol. 3", "Extras" for "Tidewater Saints Extras", and nil for a title that
    /// is only the series title plus notes in brackets, like
    /// "一只猫的存在主义思考 (一只猫丧中带…) (未读·文艺家)".
    func nameBesideSeries(long: Bool = false) -> String? {
        if number != nil { return long ? longDisplayName : displayName }
        guard let seriesTitle = series?.title, !seriesTitle.isEmpty,
              let match = title.range(of: seriesTitle, options: [.anchored, .caseInsensitive, .widthInsensitive])
        else { return title }
        let rest = String(title[match.upperBound...])
        let withoutNotes = rest.replacing(#/[(\[（【][^)\]）】]*[)\]）】]/#, with: "")
        if withoutNotes.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
            return nil
        }
        // "Tidewater Saints - Extras" → "Extras".
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:：·_,，"))
        return rest.trimmingCharacters(in: separators)
    }

    // MARK: Files on disk

    var folderURL: URL { LibraryPaths.volumeFolder(for: id) }
    var coverURL: URL { LibraryPaths.coverURL(for: id) }

    func pageURL(at index: Int) -> URL? {
        guard pageFiles.indices.contains(index) else { return nil }
        return LibraryPaths.pagesFolder(for: id).appending(path: pageFiles[index])
    }

    // MARK: Sorting

    /// The user's order from Edit first. Then numbered volumes (by number),
    /// then the rest by natural name order.
    static func readingOrder(_ a: Volume, _ b: Volume) -> Bool {
        switch (a.sortIndex, b.sortIndex) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        switch (a.number, b.number) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
