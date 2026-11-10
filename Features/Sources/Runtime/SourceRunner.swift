import Foundation
import CoreGraphics
import ImageIO

nonisolated enum SourceError: LocalizedError {
    case unsupportedFormat
    case noLists
    case message(String)
    case code(Int32)
    case badResult

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "This source uses a format that Koma does not support.")
        case .noLists: String(localized: "This source has no lists.")
        case .message(let text): text
        case .code(let code):
            switch code {
            case -2: String(localized: "This source does not support this action.")
            case -3: String(localized: "The source could not connect. Check your network and try again.")
            case -4: String(localized: "The source could not read the website. The site may have changed.")
            default: String(localized: "The source returned an error (\(code)).")
            }
        case .badResult: String(localized: "The source sent data that Koma cannot read.")
        }
    }
}

/// A source plugin that is loaded and ready.
///
/// The interpreter is not thread safe, and host calls such as `net.send` block.
/// So every call runs on one serial queue that belongs to this source, never on
/// the main actor or the Swift concurrency pool.
nonisolated final class SourceRunner: @unchecked Sendable {
    let info: SourceInfo
    private let queue: DispatchQueue
    private let wasm: WasmInstance
    private let host: SourceHost

    /// Loads main.wasm from an installed source folder and runs its `start` function.
    init(folder: URL) throws {
        let infoData = try Data(contentsOf: folder.appending(path: "source.json"))
        let info = try SourceInfo(json: infoData)
        let bytes = try [UInt8](Data(contentsOf: folder.appending(path: "main.wasm")))
        let settings = try? Data(contentsOf: folder.appending(path: "settings.json"))

        let defaults = SourceDefaults(sourceID: info.id)
        SourceSettingsDefaults.register(info: info, settingsJSON: settings, in: defaults)

        self.info = info
        queue = DispatchQueue(label: "app.koma.source.\(info.id)", qos: .userInitiated)
        host = SourceHost(defaults: defaults)
        wasm = try WasmInstance(bytes: bytes)
        host.log = { message in
            #if DEBUG
            print("[\(info.id)] \(message)")
            #endif
        }
        host.link(to: wasm)

        // aidoku-rs 0.3 sources export these. Older (0.2) sources do not.
        guard wasm.hasFunction("get_search_manga_list"), wasm.hasFunction("free_result") else {
            throw SourceError.unsupportedFormat
        }
        _ = try queue.sync {
            try wasm.call("start")
        }
    }

    private var hasImageRequestProvider: Bool { wasm.hasFunction("get_image_request") }
    private var hasPageImageProcessor: Bool { wasm.hasFunction("process_page_image") }

    // MARK: Calls

    func search(query: String?, page: Int) async throws -> SourceMangaPage {
        try await run { [self] in
            let queryDescriptor: Int32 = query.flatMap { $0.isEmpty ? nil : host.add(string: $0) } ?? -1
            var filters = PostcardWriter()
            filters.list([SourceFilterValue]()) { $1.write(&$0) }
            let bytes = try callResult("get_search_manga_list",
                                       [queryDescriptor, Int32(page), host.add(bytes: filters.bytes)])
            var reader = PostcardReader(bytes)
            return try decode { try SourceMangaPage.read(&reader) }
        }
    }

    func mangaList(listing: SourceListing, page: Int) async throws -> SourceMangaPage {
        try await run { [self] in
            guard wasm.hasFunction("get_manga_list") else { throw SourceError.noLists }
            var writer = PostcardWriter()
            listing.write(&writer)
            let bytes = try callResult("get_manga_list", [host.add(bytes: writer.bytes), Int32(page)])
            var reader = PostcardReader(bytes)
            return try decode { try SourceMangaPage.read(&reader) }
        }
    }

    /// The listings from source.json plus the ones the plugin makes at run time.
    func listings() async throws -> [SourceListing] {
        try await run { [self] in
            var listings = info.listings
            if wasm.hasFunction("get_listings"), let bytes = try? callResult("get_listings", []) {
                var reader = PostcardReader(bytes)
                if let dynamic = try? reader.list(SourceListing.read) {
                    for listing in dynamic where !listings.contains(where: { $0.id == listing.id }) {
                        listings.append(listing)
                    }
                }
            }
            return wasm.hasFunction("get_manga_list") ? listings : []
        }
    }

    /// Details and chapters. The plugin returns the full manga; fields it leaves
    /// empty keep the values from the list.
    func mangaDetails(_ manga: SourceManga) async throws -> SourceManga {
        try await run { [self] in
            var writer = PostcardWriter()
            manga.write(&writer)
            let bytes = try callResult("get_manga_update", [host.add(bytes: writer.bytes), 1, 1])
            var reader = PostcardReader(bytes)
            var result = manga
            result.merge(try decode { try SourceManga.read(&reader) })
            return result
        }
    }

    /// The pages of a chapter. Pages that the plugin drew itself come back as PNG data.
    func pages(manga: SourceManga, chapter: SourceChapter) async throws -> [ResolvedPage] {
        try await run { [self] in
            var mangaWriter = PostcardWriter()
            var listedManga = manga
            listedManga.chapters = nil
            listedManga.write(&mangaWriter)
            var chapterWriter = PostcardWriter()
            chapter.write(&chapterWriter)
            let bytes = try callResult("get_page_list", [host.add(bytes: mangaWriter.bytes),
                                                         host.add(bytes: chapterWriter.bytes)])
            var reader = PostcardReader(bytes)
            let pages = try decode { try reader.list(SourcePage.read) }
            return pages.compactMap { page in
                switch page.content {
                case let .url(url, context): return .url(url, context: context)
                case let .image(descriptor):
                    guard case .image(let image)? = host.value(descriptor), let data = image.bytes else { return nil }
                    return .data(data, fileExtension: ChapterFile.fileExtension(for: data))
                case let .zip(url, path): return .zip(url, path: path)
                case .text: return nil
                }
            }
        }
    }

    /// The request for a page image or a cover, with the headers the site needs.
    func imageRequest(for url: String, context: [String: String]?) async throws -> URLRequest {
        try await run { [self] in
            if hasImageRequestProvider {
                var urlWriter = PostcardWriter()
                urlWriter.string(url)
                let contextDescriptor = context.map { context -> Int32 in
                    var writer = PostcardWriter()
                    writer.stringMap(context)
                    return host.add(bytes: writer.bytes)
                } ?? -1
                if let bytes = try? callResult("get_image_request", [host.add(bytes: urlWriter.bytes), contextDescriptor]) {
                    var reader = PostcardReader(bytes)
                    if let descriptor = try? reader.int(),
                       case .request(let request)? = host.value(Int32(truncatingIfNeeded: descriptor)),
                       request.request.url?.scheme?.hasPrefix("http") == true {
                        return request.request
                    }
                }
            }
            guard let imageURL = SourceHost.makeURL(url) else { throw SourceError.badResult }
            var request = URLRequest(url: imageURL)
            if let base = info.baseURL {
                request.setValue(base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/",
                                 forHTTPHeaderField: "Referer")
            }
            return request
        }
    }

    /// Lets the plugin change a downloaded page (for example, put scrambled tiles back).
    /// Returns nil when the plugin has no image processor; then use the data as it is.
    func processPageImage(_ data: Data, response: HTTPURLResponse?, request: URLRequest,
                          context: [String: String]?) async throws -> Data? {
        try await run { [self] in
            guard hasPageImageProcessor else { return nil }
            var writer = PostcardWriter()
            writer.uint(response?.statusCode ?? 200)
            var headers: [String: String] = [:]
            for (key, value) in response?.allHeaderFields ?? [:] {
                headers["\(key)"] = "\(value)"
            }
            writer.stringMap(headers)
            writer.optionalString(request.url?.absoluteString)
            writer.stringMap(request.allHTTPHeaderFields ?? [:])
            writer.i32(host.add(.image(HostImage(data: data))))
            let contextDescriptor = context.map { context -> Int32 in
                var contextWriter = PostcardWriter()
                contextWriter.stringMap(context)
                return host.add(bytes: contextWriter.bytes)
            } ?? -1
            let bytes = try callResult("process_page_image", [host.add(bytes: writer.bytes), contextDescriptor])
            var reader = PostcardReader(bytes)
            guard let descriptor = try? reader.int(),
                  case .image(let result)? = host.value(Int32(truncatingIfNeeded: descriptor)),
                  let bytes = result.bytes
            else { throw SourceError.badResult }
            return bytes
        }
    }

    // MARK: Plumbing

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                // Objects from the last call are no longer needed.
                host.clear()
                host.lastPrint = nil
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func decode<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw SourceError.badResult }
    }

    /// Calls an export that returns an encoded result, reads it, and frees it.
    private func callResult(_ name: String, _ arguments: [Int32]) throws -> [UInt8] {
        wasm.lastPrint = nil
        let result: Int32
        do {
            guard let value = try wasm.call(name, arguments) else { throw SourceError.badResult }
            result = value
        } catch let error as WasmError {
            if case .trap = error, let printed = host.lastPrint { throw SourceError.message(printed) }
            throw error
        }
        guard result > 0 else {
            if result == 0 { throw SourceError.badResult }
            throw SourceError.code(result)
        }
        defer { _ = try? wasm.call("free_result", [result]) }
        let length = try wasm.readI32(at: result)
        if length == -1 {
            // [-1][capacity][total length][message]
            let total = try wasm.readI32(at: result + 8)
            let message = try wasm.readBytes(at: result + 12, count: max(0, Int(total) - 12))
            throw SourceError.message(String(decoding: message, as: UTF8.self))
        }
        guard length >= 8 else { throw SourceError.badResult }
        return try wasm.readBytes(at: result + 8, count: Int(length) - 8)
    }
}

nonisolated enum ChapterFile {
    /// The extension for the image format, from the first bytes of the file.
    static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8...11], as: UTF8.self)
            return brand.hasPrefix("avi") ? "avif" : "heic"
        }
        return "jpg"
    }

    /// Checks the header only. It does not decode the pixels.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }
}

/// A page, ready to download.
nonisolated enum ResolvedPage: Sendable {
    case url(String, context: [String: String]?)
    case data(Data, fileExtension: String)
    case zip(String, path: String)
}
