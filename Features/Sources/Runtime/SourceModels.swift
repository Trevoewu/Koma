import Foundation

// The data that source plugins send and receive (aidoku-rs 0.3 `structs`).
// The field order must match the Rust structs: postcard has no field names.

nonisolated enum SourceMangaStatus: Int, Sendable, Hashable, Codable {
    case unknown, ongoing, completed, cancelled, hiatus
}

nonisolated enum SourceViewer: Int, Sendable, Hashable, Codable {
    case unknown, leftToRight, rightToLeft, vertical, webtoon
}

nonisolated struct SourceManga: Sendable, Hashable, Identifiable, Codable {
    var key: String = ""
    var title: String = ""
    var cover: String?
    var artists: [String]?
    var authors: [String]?
    var summary: String?
    var url: String?
    var tags: [String]?
    var status: SourceMangaStatus = .unknown
    /// 0 unknown, 1 safe, 2 suggestive, 3 NSFW.
    var contentRating: Int = 0
    var viewer: SourceViewer = .unknown
    var updateStrategy: Int = 0
    var nextUpdateTime: Int64?
    var chapters: [SourceChapter]?

    var id: String { key }

    static func read(_ reader: inout PostcardReader) throws -> SourceManga {
        var manga = SourceManga()
        manga.key = try reader.string()
        manga.title = try reader.string()
        manga.cover = try reader.optionalString()
        manga.artists = try reader.optional { try $0.stringList() }
        manga.authors = try reader.optional { try $0.stringList() }
        manga.summary = try reader.optionalString()
        manga.url = try reader.optionalString()
        manga.tags = try reader.optional { try $0.stringList() }
        manga.status = SourceMangaStatus(rawValue: try reader.uint()) ?? .unknown
        manga.contentRating = try reader.uint()
        manga.viewer = SourceViewer(rawValue: try reader.uint()) ?? .unknown
        manga.updateStrategy = try reader.uint()
        manga.nextUpdateTime = try reader.optional { try $0.int() }
        manga.chapters = try reader.optional { try $0.list(SourceChapter.read) }
        return manga
    }

    func write(_ writer: inout PostcardWriter) {
        writer.string(key)
        writer.string(title)
        writer.optionalString(cover)
        writer.optional(artists) { $0.stringList($1) }
        writer.optional(authors) { $0.stringList($1) }
        writer.optionalString(summary)
        writer.optionalString(url)
        writer.optional(tags) { $0.stringList($1) }
        writer.uint(status.rawValue)
        writer.uint(contentRating)
        writer.uint(viewer.rawValue)
        writer.uint(updateStrategy)
        writer.optional(nextUpdateTime) { $0.int($1) }
        writer.optional(chapters) { writer, chapters in writer.list(chapters) { $1.write(&$0) } }
    }

    /// Fills the fields that `other` has. Like `Manga::copy_from` in aidoku-rs.
    mutating func merge(_ other: SourceManga) {
        key = other.key
        if !other.title.isEmpty { title = other.title }
        cover = other.cover ?? cover
        artists = other.artists ?? artists
        authors = other.authors ?? authors
        summary = other.summary ?? summary
        url = other.url ?? url
        tags = other.tags ?? tags
        status = other.status
        contentRating = other.contentRating
        viewer = other.viewer
        updateStrategy = other.updateStrategy
        nextUpdateTime = other.nextUpdateTime ?? nextUpdateTime
        chapters = other.chapters ?? chapters
    }

    /// Authors, then artists who are not also authors.
    var creatorLine: String? {
        var names = authors ?? []
        for artist in artists ?? [] where !names.contains(artist) { names.append(artist) }
        return names.isEmpty ? nil : names.formatted(.list(type: .and, width: .narrow))
    }
}

nonisolated struct SourceChapter: Sendable, Hashable, Identifiable, Codable {
    var key: String = ""
    var title: String?
    var chapterNumber: Float?
    var volumeNumber: Float?
    var dateUploaded: Int64?
    var scanlators: [String]?
    var url: String?
    var language: String?
    var thumbnail: String?
    var locked: Bool = false

    var id: String { key }

    static func read(_ reader: inout PostcardReader) throws -> SourceChapter {
        var chapter = SourceChapter()
        chapter.key = try reader.string()
        chapter.title = try reader.optionalString()
        chapter.chapterNumber = try reader.optional { try $0.f32() }
        chapter.volumeNumber = try reader.optional { try $0.f32() }
        chapter.dateUploaded = try reader.optional { try $0.int() }
        chapter.scanlators = try reader.optional { try $0.stringList() }
        chapter.url = try reader.optionalString()
        chapter.language = try reader.optionalString()
        chapter.thumbnail = try reader.optionalString()
        chapter.locked = try reader.bool()
        return chapter
    }

    func write(_ writer: inout PostcardWriter) {
        writer.string(key)
        writer.optionalString(title)
        writer.optional(chapterNumber) { $0.f32($1) }
        writer.optional(volumeNumber) { $0.f32($1) }
        writer.optional(dateUploaded) { $0.int($1) }
        writer.optional(scanlators) { $0.stringList($1) }
        writer.optionalString(url)
        writer.optionalString(language)
        writer.optionalString(thumbnail)
        writer.bool(locked)
    }

    var uploadDate: Date? { dateUploaded.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// "Vol. 2 Ch. 12.5", "Ch. 3", or nil.
    var numberLabel: String? {
        var parts: [String] = []
        if let volumeNumber { parts.append(String(localized: "Vol. \(Self.format(volumeNumber))")) }
        if let chapterNumber { parts.append(String(localized: "Ch. \(Self.format(chapterNumber))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "1198", "12.5": no group separator, as chapter numbers are written.
    static func format(_ number: Float) -> String {
        Double(number).formatted(.number.grouping(.never))
    }

    /// The name of the chapter in lists. A title that already has the chapter
    /// number ("Chapter 1198: Island of Monsters") is shown alone.
    var displayTitle: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let trimmedTitle, let chapterNumber, volumeNumber == nil,
           trimmedTitle.range(of: #"(?<![0-9.])"# + NSRegularExpression.escapedPattern(for: Self.format(chapterNumber)) + #"(?![0-9])"#,
                              options: .regularExpression) != nil {
            return trimmedTitle
        }
        switch (numberLabel, trimmedTitle) {
        case let (number?, title?): return "\(number) · \(title)"
        case let (number?, nil): return number
        case let (nil, title?): return title
        default: return key
        }
    }
}

nonisolated struct SourceMangaPage: Sendable {
    var entries: [SourceManga]
    var hasNextPage: Bool

    static func read(_ reader: inout PostcardReader) throws -> SourceMangaPage {
        SourceMangaPage(entries: try reader.list(SourceManga.read), hasNextPage: try reader.bool())
    }
}

nonisolated struct SourceListing: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    /// 0 = default (grid), 1 = list.
    var kind: Int = 0

    static func read(_ reader: inout PostcardReader) throws -> SourceListing {
        SourceListing(id: try reader.string(), name: try reader.string(), kind: try reader.uint())
    }

    func write(_ writer: inout PostcardWriter) {
        writer.string(id)
        writer.string(name)
        writer.uint(kind)
    }
}

/// One page of a chapter.
nonisolated enum SourcePageContent: Sendable {
    case url(String, context: [String: String]?)
    case text(String)
    /// An image the source made with its canvas functions (a descriptor in the host store).
    case image(Int32)
    /// A file inside a zip archive at a URL: (url, path in the archive).
    case zip(String, String)
}

nonisolated struct SourcePage: Sendable {
    var content: SourcePageContent
    var thumbnail: String?
    var hasDescription: Bool
    var description: String?

    static func read(_ reader: inout PostcardReader) throws -> SourcePage {
        let content: SourcePageContent
        switch try reader.uint() {
        case 0:
            let url = try reader.string()
            content = .url(url, context: try reader.optional { try $0.stringMap() })
        case 1: content = .text(try reader.string())
        case 2: content = .image(Int32(truncatingIfNeeded: try reader.int()))
        case 3: content = .zip(try reader.string(), try reader.string())
        default: throw PostcardError()
        }
        return SourcePage(content: content,
                          thumbnail: try reader.optionalString(),
                          hasDescription: try reader.bool(),
                          description: try reader.optionalString())
    }
}

/// A filter value for a search. Koma sends none for now; the type is here for the ABI.
nonisolated enum SourceFilterValue: Sendable {
    case text(id: String, value: String)

    func write(_ writer: inout PostcardWriter) {
        switch self {
        case let .text(id, value):
            writer.uint(0)
            writer.string(id)
            writer.string(value)
        }
    }
}

extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
