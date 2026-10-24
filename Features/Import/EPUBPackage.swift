import Foundation

/// The parts of an EPUB that Koma uses: the page images in reading order and
/// the book metadata.
///
/// Koma shows images only. A comic EPUB has one image per spine document
/// (`<img src>` or SVG `<image xlink:href>`). A text book (a novel, maybe with
/// a few illustrations) is marked with `isTextBook`, and the importer refuses it.
///
/// Spine documents are often HTML that is not valid XML, so they are scanned
/// with a pattern, not parsed. The package file (OPF) is real XML.
nonisolated struct EPUBPackage: Equatable, Sendable {
    /// Archive entry names of the page images, in reading order, without duplicates.
    var pagePaths: [String] = []
    var title: String?
    var creators: [String] = []
    var subjects: [String] = []
    var summary: String?
    /// calibre:series, or the EPUB 3 "belongs-to-collection".
    var seriesTitle: String?
    var seriesIndex: Double?
    /// `<spine page-progression-direction="rtl">`.
    var isRightToLeft = false
    var isTextBook = false

    /// "A, B" without duplicates.
    var author: String? {
        var unique: [String] = []
        for name in creators where !unique.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            unique.append(name)
        }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    static let containerPath = "META-INF/container.xml"

    /// `names` are all entry names in the archive. `read` returns the data of
    /// one entry (nil if it is missing or too large).
    /// Returns nil if the archive has no readable EPUB package.
    static func read(names: [String], read: (String) -> Data?) -> EPUBPackage? {
        let lookup = EntryLookup(names: names)
        guard let containerName = lookup.find(containerPath),
              let containerData = read(containerName),
              let opfPath = ContainerParser.rootfile(in: containerData),
              let opfName = lookup.find(opfPath),
              let opfData = read(opfName),
              let opf = OPFParser.parse(opfData)
        else { return nil }

        var package = EPUBPackage()
        package.title = opf.title
        package.creators = opf.creators
        package.subjects = opf.subjects.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        package.summary = opf.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 }
        package.seriesTitle = opf.seriesTitle
        package.seriesIndex = opf.seriesIndex
        package.isRightToLeft = opf.pageProgression == "rtl"

        let opfFolder = folder(of: opfName)
        let items = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var pages: [String] = []
        var seen = Set<String>()
        var documents = 0
        var documentsWithImages = 0
        var textLength = 0

        for idref in opf.spine {
            guard let item = items[idref],
                  let docName = lookup.find(resolve(item.href, from: opfFolder))
            else { continue }

            // A spine item can be an image itself.
            if item.mediaType.hasPrefix("image/") {
                if seen.insert(docName).inserted { pages.append(docName) }
                documents += 1
                documentsWithImages += 1
                continue
            }
            guard let data = read(docName) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            documents += 1
            textLength += visibleTextLength(html)

            let docFolder = folder(of: docName)
            var found = false
            for ref in imageReferences(in: html) {
                guard let name = lookup.find(resolve(ref, from: docFolder)) else { continue }
                found = true
                if seen.insert(name).inserted { pages.append(name) }
            }
            if found { documentsWithImages += 1 }
        }

        // A text book: most spine documents have no image, or there is much
        // more text than a comic has (an afterword is fine).
        package.isTextBook = documents > 0
            && (documentsWithImages * 2 < documents || textLength > 400 * max(documentsWithImages, 1))

        // Some fixed-layout books draw pages with CSS backgrounds. Then use the
        // images of the manifest in manifest order.
        if pages.isEmpty, !package.isTextBook {
            for item in opf.manifest where item.mediaType.hasPrefix("image/") {
                if let name = lookup.find(resolve(item.href, from: opfFolder)), seen.insert(name).inserted {
                    pages.append(name)
                }
            }
        }
        package.pagePaths = pages
        return package
    }

    // MARK: Paths

    /// "OEBPS/content.opf" → "OEBPS/". "content.opf" → "".
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// Resolves a link from a document in `folder`: removes "#fragment" and
    /// "?query", decodes "%20" and "&amp;", and handles "." and "..".
    /// Returns "" for links to other places (http:, data:).
    static func resolve(_ href: String, from folder: String) -> String {
        var link = decodeEntities(href.trimmingCharacters(in: .whitespacesAndNewlines))
        if let cut = link.firstIndex(where: { $0 == "#" || $0 == "?" }) { link = String(link[..<cut]) }
        if link.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:/#) != nil { return "" }
        link = link.removingPercentEncoding ?? link

        let joined = link.hasPrefix("/") ? String(link.dropFirst()) : folder + link
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    // MARK: HTML scanning

    /// The `src` of `<img>` and the `href` / `xlink:href` of SVG `<image>`, in document order.
    static func imageReferences(in html: String) -> [String] {
        let pattern = #/(?i)<(?:img|image)\b[^>]*?\s(?:src|xlink:href|href)\s*=\s*(?:"([^"]*)"|'([^']*)')/#
        return html.matches(of: pattern).compactMap { match in
            let value = match.output.1 ?? match.output.2
            return value.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The number of visible, non-space characters in the body.
    static func visibleTextLength(_ html: String) -> Int {
        var text = html
        if let body = text.firstRange(of: #/(?i)<body\b/#) { text = String(text[body.lowerBound...]) }
        text.replace(#/(?is)<(script|style)\b.*?</\1\s*>/#, with: "")
        return plainText(text).count(where: { !$0.isWhitespace })
    }

    /// Tags removed, entities decoded, white space collapsed.
    static func plainText(_ html: String) -> String {
        var text = html.replacing(#/(?i)<br\s*/?>|</p\s*>/#, with: "\n")
        text.replace(#/<[^>]*>/#, with: "")
        text = decodeEntities(text)
        let lines = text.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
                                ("&#39;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        result.replace(#/&#(x?)([0-9A-Fa-f]+);/#) { match in
            let value = UInt32(match.output.2, radix: match.output.1.isEmpty ? 10 : 16)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        // Last, so "&amp;lt;" becomes "&lt;" and not "<".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Finds entry names exactly, else without regard to case
/// (EPUBs made on Windows sometimes link "Images/1.JPG" to "images/1.jpg").
private nonisolated struct EntryLookup {
    private let exact: Set<String>
    private let folded: [String: String]

    init(names: [String]) {
        exact = Set(names)
        folded = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func find(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if exact.contains(path) { return path }
        return folded[path.lowercased()]
    }
}

// MARK: XML

/// META-INF/container.xml → the path of the first package file.
private nonisolated final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootfile(in data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.path
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard path == nil, name == "rootfile", let fullPath = attributes["full-path"], !fullPath.isEmpty else { return }
        path = EPUBPackage.resolve(fullPath, from: "")
        parser.abortParsing()
    }
}

/// The package document (content.opf).
private nonisolated final class OPFParser: NSObject, XMLParserDelegate {
    struct Item {
        var id: String
        var href: String
        var mediaType: String
    }

    struct Result {
        var title: String?
        var creators: [String] = []
        var subjects: [String] = []
        var description: String?
        var seriesTitle: String?
        var seriesIndex: Double?
        var manifest: [Item] = []
        var spine: [String] = []
        var pageProgression: String?
    }

    private var result = Result()
    private var text = ""
    private var metaAttributes: [String: String] = [:]
    /// EPUB 3 collection ids → their group-position.
    private var collectionIDs: [String] = []
    private var refines: [(target: String, property: String, value: String)] = []

    static func parse(_ data: Data) -> Result? {
        let delegate = OPFParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.result.spine.isEmpty else { return nil }
        delegate.applyRefines()
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                result.manifest.append(Item(id: id, href: href, mediaType: attributes["media-type"]?.lowercased() ?? ""))
            }
        case "itemref":
            if let idref = attributes["idref"] { result.spine.append(idref) }
        case "spine":
            result.pageProgression = attributes["page-progression-direction"]?.lowercased()
        case "meta":
            metaAttributes = attributes
            // EPUB 2: <meta name="calibre:series" content="…"/>
            if let metaName = attributes["name"], let content = attributes["content"]?.trimmingCharacters(in: .whitespaces),
               !content.isEmpty {
                switch metaName {
                case "calibre:series": result.seriesTitle = content
                case "calibre:series_index": result.seriesIndex = Double(content)
                default: break
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard !value.isEmpty else { return }
        let isDC = namespaceURI == "http://purl.org/dc/elements/1.1/"
        switch (isDC, name) {
        case (true, "title"): if result.title == nil { result.title = value }
        case (true, "creator"): result.creators.append(value)
        case (true, "subject"): result.subjects.append(value)
        case (true, "description"): if result.description == nil { result.description = value }
        case (false, "meta"):
            // EPUB 3: <meta property="belongs-to-collection" id="c1">Series</meta>
            //         <meta refines="#c1" property="group-position">3</meta>
            let property = metaAttributes["property"] ?? ""
            if let target = metaAttributes["refines"] {
                refines.append((String(target.drop(while: { $0 == "#" })), property, value))
            } else if property == "belongs-to-collection", result.seriesTitle == nil {
                result.seriesTitle = value
                if let id = metaAttributes["id"] { collectionIDs.append(id) }
            }
        default:
            break
        }
    }

    private func applyRefines() {
        guard result.seriesIndex == nil, let id = collectionIDs.first else { return }
        if let position = refines.first(where: { $0.target == id && $0.property == "group-position" }) {
            result.seriesIndex = Double(position.value)
        }
    }
}
