import Foundation
import SwiftData

/// A group of volumes, for example "Tidewater Saints" with 8 volumes.
///
/// All properties have default values and all relationships are optional.
/// CloudKit needs this, so the model is ready if we add iCloud sync later.
@Model
final class Series {
    var id: UUID = UUID()
    var title: String = ""
    var author: String?
    var summary: String?

    /// nil = use the default mode from Settings.
    var readingModeRaw: String?

    var dateAdded: Date = Date.now
    var lastReadAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Volume.series)
    var volumes: [Volume]? = []

    @Relationship(inverse: \Tag.series)
    var tags: [Tag]? = []

    init(title: String, author: String? = nil) {
        self.title = title
        self.author = author
    }
}

extension Series {
    /// The mode saved for this series, or nil.
    var readingMode: ReadingMode? {
        get { readingModeRaw.flatMap(ReadingMode.init(rawValue:)) }
        set { readingModeRaw = newValue?.rawValue }
    }

    func effectiveReadingMode(default defaultMode: ReadingMode) -> ReadingMode {
        readingMode ?? defaultMode
    }

    var volumeCount: Int { volumes?.count ?? 0 }

    /// Volumes in reading order (by volume number, then by name).
    var sortedVolumes: [Volume] {
        (volumes ?? []).sorted(by: Volume.readingOrder)
    }

    /// The volume that "Continue" opens:
    /// the most recently read unfinished volume, else the first unfinished one.
    var continueVolume: Volume? {
        let unfinished = sortedVolumes.filter { !$0.isFinished }
        let started = unfinished.filter { $0.lastReadAt != nil }
        if let recent = started.max(by: { $0.lastReadAt! < $1.lastReadAt! }) {
            return recent
        }
        return unfinished.first
    }

    var isFinished: Bool {
        let all = volumes ?? []
        return !all.isEmpty && all.allSatisfy(\.isFinished)
    }

    var totalPages: Int {
        (volumes ?? []).reduce(0) { $0 + $1.pageCount }
    }

    var sortedTagNames: [String] {
        (tags ?? []).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
