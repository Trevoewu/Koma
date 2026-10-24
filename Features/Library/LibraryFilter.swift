import Foundation
import SwiftData

/// The chips above the library: All / Reading / Unread / Finished.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, reading, unread, finished

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all:      "All"
        case .reading:  "Reading"
        case .unread:   "Unread"
        case .finished: "Finished"
        }
    }

    func matches(_ series: Series) -> Bool {
        switch self {
        case .all:      true
        case .reading:  series.isReading
        case .unread:   !series.hasStarted
        case .finished: series.isFinished
        }
    }

    /// Shown in place of the grid when no series matches.
    var emptyMessage: LocalizedStringResource {
        switch self {
        case .all:      "Your library is empty."
        case .reading:  "Nothing in progress. Open a volume to start reading."
        case .unread:   "You have started every series."
        case .finished: "No finished series yet."
        }
    }
}

/// Sort order of the "All Series" grid. Saved in UserDefaults.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, added, title

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .recent: "Recently Read"
        case .added:  "Recently Added"
        case .title:  "Title"
        }
    }

    func areInIncreasingOrder(_ a: Series, _ b: Series) -> Bool {
        switch self {
        case .recent:
            // Never-read series follow, newest import first.
            (a.lastReadAt ?? .distantPast, a.dateAdded) > (b.lastReadAt ?? .distantPast, b.dateAdded)
        case .added:
            a.dateAdded > b.dateAdded
        case .title:
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

extension Series {
    var hasStarted: Bool {
        (volumes ?? []).contains { $0.hasStarted || $0.isFinished }
    }

    var isReading: Bool { hasStarted && !isFinished }

    /// Imported in the last 7 days and not opened yet.
    var isNew: Bool {
        !hasStarted && dateAdded > Date.now.addingTimeInterval(-7 * 24 * 3600)
    }

    /// The cover of the first volume.
    var coverURL: URL? { sortedVolumes.first?.coverURL }

    /// The dark label on the cover: "Finished", "NEW" or "8 vols".
    var badgeText: String {
        if isFinished { return String(localized: "Finished") }
        if isNew { return String(localized: "NEW") }
        return String(localized: "\(volumeCount) vols")
    }

    /// The series for the "Continue" card: the most recently read unfinished one.
    static func continueCandidate(in all: [Series]) -> Series? {
        all.filter { $0.lastReadAt != nil && !$0.isFinished && $0.continueVolume != nil }
            .max { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }
    }
}

extension Volume {
    /// "Vol. 3 · Page 42 of 186". A volume named like its series shows only the page.
    /// A long name (an EPUB title, a file name) is cut, so the page always shows.
    var progressText: String {
        let page = String(localized: "Page \(currentPage + 1) of \(pageCount)")
        guard let name = nameBesideSeries() else { return page }
        let shown = name.count > 24 ? name.prefix(23) + "…" : name
        return "\(shown) · \(page)"
    }
}

/// Changes to the library that touch files on disk as well as SwiftData.
enum LibraryActions {
    /// Deletes the series, its volumes and all their pages and covers.
    static func delete(_ series: Series, in context: ModelContext) {
        for volume in series.volumes ?? [] {
            try? LibraryPaths.deleteFiles(for: volume.id)
        }
        context.delete(series)
        try? context.save()
    }

    static func markFinished(_ volume: Volume) {
        volume.isFinished = true
        volume.currentPage = max(volume.pageCount - 1, 0)
        try? volume.modelContext?.save()
    }
}

/// Keys for @AppStorage and UserDefaults.
nonisolated enum SettingsKey {
    static let appearance = "appearance"
    static let defaultReadingMode = "defaultReadingMode"
    static let detectWebtoons = "detectWebtoons"
    static let keepScreenOn = "keepScreenOn"
    static let librarySort = "librarySort"
}
