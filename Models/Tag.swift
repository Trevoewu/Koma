import Foundation
import SwiftData

/// A tag such as "Fantasy" or "Ongoing". One tag can belong to many series.
/// The importer reuses an existing tag with the same name instead of making a new one.
@Model
final class Tag {
    var name: String = ""
    var series: [Series]? = []

    init(name: String) {
        self.name = name
    }
}
