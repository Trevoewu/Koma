import Foundation

/// The fields we use from ComicInfo.xml (the ComicRack metadata format).
nonisolated struct ComicInfo: Equatable, Sendable {
    var series: String?
    var number: String?
    var volume: String?
    var title: String?
    var writer: String?
    var penciller: String?
    var genre: String?
    var tags: String?
    var summary: String?
    var manga: String?

    /// nil if the data is not a ComicInfo document.
    init?(data: Data) {
        let delegate = ComicInfoParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawRoot else { return nil }
        self = delegate.info
    }

    init() {}

    var seriesTitle: String? { series.nonEmpty }
    var volumeTitle: String? { title.nonEmpty }

    /// "Number" first, then "Volume". Decimals are kept: "12.5".
    var volumeNumber: Double? {
        for text in [number, volume] {
            if let text = text.nonEmpty, let value = Double(text.replacingOccurrences(of: ",", with: ".")) {
                return value
            }
        }
        return nil
    }

    /// Writer, plus Penciller if different: "Rin Aoyama, Kai Mori".
    var author: String? {
        let names = [writer.nonEmpty, penciller.nonEmpty].compactMap { $0 }
        var unique: [String] = []
        for name in names where !unique.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            unique.append(name)
        }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    /// Genre + Tags, split at commas, trimmed, without duplicates.
    var tagNames: [String] {
        var result: [String] = []
        for list in [genre, tags].compactMap({ $0 }) {
            for part in list.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                else { continue }
                result.append(name)
            }
        }
        return result
    }

    var isRightToLeft: Bool {
        manga?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("YesAndRightToLeft") == .orderedSame
    }
}

private nonisolated final class ComicInfoParserDelegate: NSObject, XMLParserDelegate {
    var info = ComicInfo()
    var sawRoot = false
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if path.isEmpty { sawRoot = name == "ComicInfo" }
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        // Only direct children of <ComicInfo>.
        guard sawRoot, path.count == 2 else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "Series": info.series = value
        case "Number": info.number = value
        case "Volume": info.volume = value
        case "Title": info.title = value
        case "Writer": info.writer = value
        case "Penciller": info.penciller = value
        case "Genre": info.genre = value
        case "Tags": info.tags = value
        case "Summary": info.summary = value
        case "Manga": info.manga = value
        default: break
        }
    }
}

nonisolated extension Optional where Wrapped == String {
    /// The trimmed string, or nil if it is nil or empty.
    var nonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
