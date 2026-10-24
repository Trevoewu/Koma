import Foundation

/// How the reader shows pages.
enum ReadingMode: String, CaseIterable, Identifiable, Codable {
    case rightToLeft
    case leftToRight
    case vertical

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .rightToLeft: "Right to Left"
        case .leftToRight: "Left to Right"
        case .vertical:    "Vertical Scroll"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .rightToLeft: "Japanese manga"
        case .leftToRight: "Comics, most manhua"
        case .vertical:    "Webtoons"
        }
    }

    var systemImage: String {
        switch self {
        case .rightToLeft: "arrow.left"
        case .leftToRight: "arrow.right"
        case .vertical:    "arrow.down"
        }
    }
}
