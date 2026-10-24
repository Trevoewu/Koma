import Foundation

/// Finds the series title and the volume number in a file name,
/// for files without ComicInfo.xml.
///
///   "[Group] Tidewater Saints v03 (2021).cbz"  → "Tidewater Saints", 3
///   "潮汐圣徒 第3卷.zip"                          → "潮汐圣徒", 3
///   "Night Bus Vol.12.5 - Detour.zip"           → "Night Bus", 12.5
nonisolated enum FileNameParser {
    struct Result: Equatable, Sendable {
        var seriesTitle: String
        var number: Double?
    }

    /// `name` is the file name. An archive extension is removed.
    static func parse(_ name: String) -> Result {
        var base = name
        let ext = (name as NSString).pathExtension.lowercased()
        if ["zip", "cbz"].contains(ext) { base = (name as NSString).deletingPathExtension }
        base = halfWidthDigits(base).replacingOccurrences(of: "_", with: " ")

        // 1. An explicit volume marker anywhere, also inside brackets: "[Vol.03]".
        if let match = explicitNumber(in: base) {
            let before = clean(stripBrackets(String(base[..<match.range.lowerBound])))
            let after = clean(stripBrackets(String(base[match.range.upperBound...])))
            let title = before.isEmpty ? after : before
            return Result(seriesTitle: title.isEmpty ? fallbackTitle(base) : title, number: match.number)
        }

        // 2. A number at the end, after brackets are gone: "Tidewater Saints 03".
        let stripped = clean(stripBrackets(base))
        if let match = stripped.firstMatch(of: #/[\s\-–—.]+([0-9]+(?:\.[0-9]+)?)\s*$/#),
           let number = Double(match.output.1) {
            let title = clean(String(stripped[..<match.range.lowerBound]))
            if !title.isEmpty { return Result(seriesTitle: title, number: number) }
        }

        return Result(seriesTitle: stripped.isEmpty ? fallbackTitle(base) : stripped, number: nil)
    }

    // MARK: Volume markers

    private struct Match {
        var range: Range<String.Index>
        var number: Double
    }

    /// The first pattern in this list that matches wins.
    private static func explicitNumber(in text: String) -> Match? {
        let patterns: [Regex<(Substring, Substring)>] = [
            #/第\s*([0-9]+(?:\.[0-9]+)?)\s*[卷巻册冊话話集回部]/#,
            #/([0-9]+(?:\.[0-9]+)?)\s*[巻卷册冊]/#,
            #/\b(?:volume|vol|v)\.?\s*([0-9]+(?:\.[0-9]+)?)/#.ignoresCase(),
            #/\b(?:chapter|ch)\.?\s*([0-9]+(?:\.[0-9]+)?)/#.ignoresCase(),
            #/#\s*([0-9]+(?:\.[0-9]+)?)/#
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern), let number = Double(match.output.1) {
                return Match(range: match.range, number: number)
            }
        }
        return nil
    }

    // MARK: Cleanup

    /// Removes "[Group]", "(2021)", "{Digital}", "【汉化】", "（完）".
    /// 「」 and 『』 stay, because they often hold the title itself.
    static func stripBrackets(_ text: String) -> String {
        text.replacing(#/\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|【[^】]*】|（[^）]*）/#, with: " ")
    }

    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-–—_.,:;·~|#[](){}【】（）「」『』"))

    /// Trims separators at both ends and collapses repeated spaces.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: edgeCharacters)
    }

    /// Used when nothing is left after the markers are removed ("03.zip").
    private static func fallbackTitle(_ base: String) -> String {
        let cleaned = clean(base.replacing(#/[\[\](){}【】（）]/#, with: " "))
        return cleaned.isEmpty ? base : cleaned
    }

    /// "０３" → "03". Only digits and the full-width dot, so katakana stay full-width.
    private static func halfWidthDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0xFF10...0xFF19: Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!
            case 0xFF0E: "."
            default: scalar
            }
        }))
    }
}

/// The key that decides if two titles are the same series:
/// case-folded, width-folded, punctuation and symbols removed, spaces collapsed.
///
///   "Tidewater Saints!" == "tidewater  saints" == "ＴＩＤＥＷＡＴＥＲ SAINTS"
nonisolated enum TitleNormalizer {
    static func key(_ title: String) -> String {
        // No diacritic folding: it would drop dakuten and make "が" equal "か".
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        let removed = CharacterSet.punctuationCharacters.union(.symbols)
        let kept = folded.unicodeScalars.filter { !removed.contains($0) }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
