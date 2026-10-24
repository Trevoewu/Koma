import Foundation
import ZIPFoundation

/// Turns zip entry names into readable strings.
///
/// Zips made on Chinese or Japanese Windows often store names in GB18030 or
/// Shift-JIS without the UTF-8 flag. ZIPFoundation then reads them as CP437,
/// and "第01话.jpg" becomes garbage. We take the raw bytes and choose one encoding
/// for the whole archive, so all names in one file decode the same way.
///
/// A wrong choice never breaks an import (pages get our own names), but it
/// changes the sort order and the ComicInfo.xml lookup.
nonisolated struct ArchiveNameDecoder {
    /// nil = keep ZIPFoundation's own decoding (all names are ASCII, or nothing fits).
    let encoding: String.Encoding?

    init(entries: [Entry]) {
        let nonASCII = entries.map { Self.rawName(of: $0) }.filter { data in data.contains { $0 >= 0x80 } }
        encoding = Self.chooseEncoding(for: nonASCII)
    }

    func name(of entry: Entry) -> String {
        var name = entry.path
        if let encoding, let decoded = String(data: Self.rawName(of: entry), encoding: encoding) {
            name = decoded
        }
        // Zips made on a Mac store decomposed characters (NFD). Sorting and
        // matching need the composed form.
        return name.precomposedStringWithCanonicalMapping
    }

    // MARK: Helpers

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// The name bytes as stored in the zip. ISO Latin-1 maps every byte to one
    /// scalar U+0000...U+00FF, so this round trip loses nothing.
    static func rawName(of entry: Entry) -> Data {
        Data(entry.path(using: .isoLatin1).unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    /// Order: UTF-8 (also for zips that forgot the flag), then GB18030, then Shift-JIS.
    ///
    /// GB18030 accepts almost any byte sequence, so Shift-JIS would never win.
    /// Japanese file names nearly always contain kana, and GBK text read as
    /// Shift-JIS gives half-width katakana, not full-width kana. So if Shift-JIS
    /// decodes everything and gives full-width kana, we take Shift-JIS first.
    static func chooseEncoding(for names: [Data]) -> String.Encoding? {
        guard !names.isEmpty else { return nil }

        func decodeAll(_ encoding: String.Encoding) -> [String]? {
            var result: [String] = []
            for data in names {
                guard let string = String(data: data, encoding: encoding) else { return nil }
                result.append(string)
            }
            return result
        }

        if decodeAll(.utf8) != nil { return .utf8 }

        let shiftJIS = decodeAll(.shiftJIS)
        if let shiftJIS, shiftJIS.contains(where: containsKana) { return .shiftJIS }
        if decodeAll(gb18030) != nil { return gb18030 }
        if shiftJIS != nil { return .shiftJIS }
        return nil
    }

    /// Full-width hiragana or katakana (U+3041...U+30FA).
    static func containsKana(_ string: String) -> Bool {
        string.unicodeScalars.contains { (0x3041...0x30FA).contains($0.value) }
    }
}
