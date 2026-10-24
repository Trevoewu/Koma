#if DEBUG
import Foundation
import SwiftData

/// Fake library for previews and for the "Add Sample Data" button.
/// There are no real page files, so covers show the placeholder art.
/// Some series have reading progress, so the Continue card, Recently Read
/// and History have something to show.
@MainActor
enum SampleData {
    static func makeContainer() -> ModelContainer {
        let container = try! ModelContainer(
            for: Series.self, Volume.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        insert(into: container.mainContext)
        return container
    }

    private struct Spec {
        var title: String
        var author: String
        var tags: [String]
        var volumes: Int
        var pages = 180
        /// Volumes 1...finished are read to the end.
        var finished = 0
        /// The open volume (finished + 1): the page and how long ago.
        var current: (page: Int, hoursAgo: Double)?
        var addedDaysAgo: Double = 30
    }

    private static let specs: [Spec] = [
        Spec(title: "Tidewater Saints", author: "Rin Aoyama", tags: ["Fantasy", "Seafaring", "Drama"],
             volumes: 8, pages: 186, finished: 2, current: (42, 1)),
        Spec(title: "Kitsune Post Office", author: "Haru Mizuki", tags: ["Slice of Life", "Fantasy"],
             volumes: 12, pages: 168, finished: 8, current: (120, 26)),
        Spec(title: "Iron Lantern", author: "Kenji Mori", tags: ["Action", "Mystery"],
             volumes: 21, pages: 190, finished: 13, current: (8, 50)),
        Spec(title: "Night Bus 404", author: "Lin Qiu", tags: ["Sci-Fi", "Webtoon"],
             volumes: 2, pages: 152, current: (64, 24 * 6)),
        Spec(title: "Summer Static", author: "Yuki Tanabe", tags: ["Romance"],
             volumes: 3, addedDaysAgo: 1),
        Spec(title: "Paper Moon Courier", author: "Sora Ishida", tags: ["Adventure"],
             volumes: 5, finished: 5),
        Spec(title: "Hollow Orchard", author: "Mei Hoshino", tags: ["Horror"], volumes: 6),
        Spec(title: "Glass Harbor", author: "Aki Fujita", tags: ["Drama"], volumes: 9),
        Spec(title: "The Quiet Forge", author: "Daichi Kuroda", tags: ["Fantasy"], volumes: 14)
    ]

    static func insert(into context: ModelContext) {
        var tagsByName: [String: Tag] = [:]
        func tag(_ name: String) -> Tag {
            if let existing = tagsByName[name] { return existing }
            let new = Tag(name: name)
            context.insert(new)
            tagsByName[name] = new
            return new
        }

        for spec in specs {
            let series = Series(title: spec.title, author: spec.author)
            series.dateAdded = .now.addingTimeInterval(-spec.addedDaysAgo * 24 * 3600)
            context.insert(series)
            series.tags = spec.tags.map(tag)

            for number in 1...spec.volumes {
                let pages = (1...spec.pages).map { String(format: "%04d.jpg", $0) }
                let volume = Volume(title: "\(spec.title) v\(number)", number: Double(number), pageFiles: pages)
                context.insert(volume)
                volume.series = series

                if number <= spec.finished {
                    volume.isFinished = true
                    volume.currentPage = spec.pages - 1
                    volume.lastReadAt = .now.addingTimeInterval(-Double(spec.finished - number + 2) * 24 * 3600)
                } else if number == spec.finished + 1, let current = spec.current {
                    volume.currentPage = current.page - 1
                    volume.lastReadAt = .now.addingTimeInterval(-current.hoursAgo * 3600)
                }
            }
            series.lastReadAt = (series.volumes ?? []).compactMap(\.lastReadAt).max()
        }
        try? context.save()
    }
}
#endif
