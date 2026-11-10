import Foundation

/// The parts of a plugin's source.json that Koma uses.
nonisolated struct SourceInfo: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var version: Int
    var urls: [String]
    var languages: [String]
    /// 0 safe, 1 contains NSFW, 2 primarily NSFW.
    var contentRating: Int
    var listings: [SourceListing]
    var languageSelectsMany: Bool

    var baseURL: URL? { urls.first.flatMap(URL.init(string:)) }

    init(id: String, name: String, version: Int, urls: [String] = [], languages: [String] = [],
         contentRating: Int = 0, listings: [SourceListing] = [], languageSelectsMany: Bool = false) {
        self.id = id
        self.name = name
        self.version = version
        self.urls = urls
        self.languages = languages
        self.contentRating = contentRating
        self.listings = listings
        self.languageSelectsMany = languageSelectsMany
    }

    init(json data: Data) throws {
        struct File: Decodable {
            struct Info: Decodable {
                var id: String
                var name: String
                var version: Int
                var url: String?
                var urls: [String]?
                var languages: [String]?
                var contentRating: Int?
            }
            struct Listing: Decodable {
                var id: String
                var name: String?
                var kind: Int?
            }
            struct Config: Decodable {
                var languageSelectType: String?
            }
            var info: Info
            var listings: [Listing]?
            var config: Config?
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        self.init(id: file.info.id,
                  name: file.info.name,
                  version: file.info.version,
                  urls: file.info.urls ?? file.info.url.map { [$0] } ?? [],
                  languages: file.info.languages ?? [],
                  contentRating: file.info.contentRating ?? 0,
                  listings: (file.listings ?? []).map { SourceListing(id: $0.id, name: $0.name ?? $0.id, kind: $0.kind ?? 0) },
                  languageSelectsMany: file.config?.languageSelectType == "multi")
    }
}

/// Values from settings.json and source.json that a plugin expects to find in its defaults.
nonisolated enum SourceSettingsDefaults {
    static func register(info: SourceInfo, settingsJSON: Data?, in defaults: SourceDefaults) {
        if let url = info.urls.first {
            defaults.register("url", encode(string: url))
        }
        if !info.languages.isEmpty {
            defaults.register("languages", encode(strings: preferredLanguages(for: info)))
        }
        guard let settingsJSON,
              let items = try? JSONSerialization.jsonObject(with: settingsJSON) as? [[String: Any]]
        else { return }
        register(items, in: defaults)
    }

    private static func register(_ items: [[String: Any]], in defaults: SourceDefaults) {
        for item in items {
            if let children = item["items"] as? [[String: Any]] {
                register(children, in: defaults)
            }
            guard let key = item["key"] as? String, let value = item["default"] else { continue }
            switch (item["type"] as? String, value) {
            case ("switch", let flag as Bool):
                defaults.register(key, [flag ? 1 : 0])
            case ("stepper", let number as NSNumber):
                var writer = PostcardWriter()
                if number.doubleValue.rounded() == number.doubleValue {
                    writer.i32(number.int32Value)
                } else {
                    writer.f32(number.floatValue)
                }
                defaults.register(key, writer.bytes)
            case (_, let strings as [String]):
                defaults.register(key, encode(strings: strings))
            case (_, let string as String):
                defaults.register(key, encode(string: string))
            case (_, let flag as Bool):
                defaults.register(key, [flag ? 1 : 0])
            default:
                continue
            }
        }
    }

    /// The device languages that the source has, else its first language.
    static func preferredLanguages(for info: SourceInfo) -> [String] {
        var matches: [String] = []
        for preferred in Locale.preferredLanguages {
            let locale = Locale(identifier: preferred)
            let code = locale.language.languageCode?.identifier ?? preferred
            let script = locale.language.script?.identifier
            let candidates = [preferred, script.map { "\(code)-\($0)" }, code].compactMap { $0 }
            if let match = candidates.lazy.compactMap({ candidate in
                info.languages.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }).first, !matches.contains(match) {
                matches.append(match)
            }
        }
        if matches.isEmpty, let first = info.languages.first { matches = [first] }
        return info.languageSelectsMany ? matches : Array(matches.prefix(1))
    }

    static func encode(string: String) -> [UInt8] {
        var writer = PostcardWriter()
        writer.string(string)
        return writer.bytes
    }

    static func encode(strings: [String]) -> [UInt8] {
        var writer = PostcardWriter()
        writer.stringList(strings)
        return writer.bytes
    }
}

/// Where installed plugins live on disk:
///
///   Application Support/Sources/<source id>/main.wasm, source.json, settings.json, icon.png
nonisolated enum SourcePaths {
    static let root: URL = URL.applicationSupportDirectory
        .appending(path: "Sources", directoryHint: .isDirectory)

    static func folder(for id: String) -> URL {
        root.appending(path: safeName(id), directoryHint: .isDirectory)
    }

    /// The only files that Koma copies out of a package.
    static let packageFiles: Set<String> = ["main.wasm", "source.json", "settings.json", "filters.json", "icon.png"]

    /// A source id as a folder name. Ids look like "en.example"; anything else is replaced.
    static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "_" : cleaned
    }
}
