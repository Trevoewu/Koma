import Foundation
import CoreGraphics
import ImageIO
import JavaScriptCore
import SwiftSoup

/// One object that the plugin refers to by a descriptor (a positive Int32).
nonisolated enum HostValue {
    /// Bytes: a string, or a postcard value that the plugin reads with read_buffer.
    case data([UInt8])
    case request(NetRequest)
    case node(SwiftSoup.Node)
    case elements(SwiftSoup.Elements)
    case nodes([SwiftSoup.Node])
    case js(JSContext)
    case image(HostImage)
    case canvas(CanvasContext)
}

/// An image for the plugin. It keeps the original bytes, because a plugin may get
/// bytes that are not an image yet (for example encrypted pages that it decrypts).
nonisolated final class HostImage {
    private(set) var data: Data?
    private var decoded: CGImage?
    private var didDecode = false

    init(data: Data) { self.data = data }

    init(cgImage: CGImage) {
        decoded = cgImage
        didDecode = true
    }

    /// nil if the bytes are not an image.
    var cgImage: CGImage? {
        if !didDecode {
            didDecode = true
            decoded = data.flatMap(SourceHost.decodeImage)
        }
        return decoded
    }

    /// The original bytes, or a PNG of a drawn image.
    var bytes: Data? { data ?? decoded.flatMap(SourceHost.encodePNG) }
}

/// An HTTP request and, after `send`, its response.
/// Used by one source thread, and by URLSession only while that thread waits.
nonisolated final class NetRequest: @unchecked Sendable {
    var request: URLRequest
    var responseData: Data?
    var response: HTTPURLResponse?
    var failed = false

    init(method: String) {
        request = URLRequest(url: URL(string: "about:blank")!)
        request.httpMethod = method
        request.timeoutInterval = 30
    }
}

/// A drawing surface for sources that rebuild scrambled pages.
nonisolated final class CanvasContext {
    let context: CGContext
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Canvas coordinates start at the top left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        self.context = context
        self.width = width
        self.height = height
    }

    func draw(_ image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// Persistent key-value settings for one source (the plugin's "defaults").
/// Values are stored as postcard bytes, exactly as the plugin wrote them.
nonisolated final class SourceDefaults: @unchecked Sendable {
    private let storeKey: String
    private let lock = NSLock()
    private var values: [String: Data]

    init(sourceID: String) {
        storeKey = "source.defaults.\(sourceID)"
        values = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data] ?? [:]
    }

    func get(_ key: String) -> [UInt8]? {
        lock.withLock { values[key].map { [UInt8]($0) } }
    }

    func set(_ key: String, _ bytes: [UInt8]?) {
        lock.withLock {
            values[key] = bytes.map { Data($0) }
            UserDefaults.standard.set(values, forKey: storeKey)
        }
    }

    /// Sets a value only if the key has none yet (defaults from settings.json).
    func register(_ key: String, _ bytes: [UInt8]) {
        lock.withLock {
            guard values[key] == nil else { return }
            values[key] = Data(bytes)
            UserDefaults.standard.set(values, forKey: storeKey)
        }
    }

    func removeAll() {
        lock.withLock {
            values = [:]
            UserDefaults.standard.removeObject(forKey: storeKey)
        }
    }
}

/// The host functions that a source plugin imports (aidoku-rs 0.3 ABI):
/// std, env, net, html, defaults, js and canvas.
///
/// All calls come from the runner's one thread, so the store needs no lock.
nonisolated final class SourceHost {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let defaults: SourceDefaults
    private var store: [Int32: HostValue] = [:]
    private var nextDescriptor: Int32 = 1
    private let session: URLSession
    private var rateLimit: (permits: Int, period: TimeInterval)?
    private var recentRequests: [Date] = []
    var log: (String) -> Void = { _ in }
    var lastPrint: String?

    init(defaults: SourceDefaults) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
    }

    // MARK: Store

    func add(_ value: HostValue) -> Int32 {
        let descriptor = nextDescriptor
        nextDescriptor = nextDescriptor == Int32.max ? 1 : nextDescriptor + 1
        store[descriptor] = value
        return descriptor
    }

    func add(bytes: [UInt8]) -> Int32 { add(.data(bytes)) }
    func add(string: String) -> Int32 { add(.data(Array(string.utf8))) }

    func value(_ descriptor: Int32) -> HostValue? { store[descriptor] }

    func remove(_ descriptor: Int32) { store[descriptor] = nil }

    /// Drops everything the last call left behind.
    func clear() { store.removeAll(keepingCapacity: true) }

    // MARK: Linking

    func link(to wasm: WasmInstance) {
        linkStd(wasm)
        linkNet(wasm)
        linkDefaults(wasm)
        HTMLImports.link(self, to: wasm)
        ScriptImports.link(self, to: wasm)
        CanvasImports.link(self, to: wasm)
    }

    private func linkStd(_ wasm: WasmInstance) {
        wasm.link("std", "destroy", "v(i)") { [unowned self] call in remove(call.i32(0)) }

        wasm.link("std", "buffer_len", "i(i)") { [unowned self] call in
            guard case .data(let bytes)? = value(call.i32(0)) else { return call.returnI32(-1) }
            call.returnI32(Int32(clamping: bytes.count))
        }

        wasm.link("std", "read_buffer", "i(iii)") { [unowned self] call in
            guard case .data(let bytes)? = value(call.i32(0)) else { return call.returnI32(-1) }
            let length = Int(call.i32(2))
            guard length >= 0, length <= bytes.count else { return call.returnI32(-2) }
            call.returnI32(call.write(Array(bytes.prefix(length)), to: call.i32(1)) ? 0 : -3)
        }

        wasm.link("std", "current_date", "F()") { call in
            call.returnF64(Date.now.timeIntervalSince1970)
        }

        wasm.link("std", "utc_offset", "I()") { call in
            call.returnI64(Int64(TimeZone.current.secondsFromGMT()))
        }

        wasm.link("std", "parse_date", "F(iiiiiiii)") { call in
            guard let string = call.string(call.i32(0), call.i32(1)),
                  let format = call.string(call.i32(2), call.i32(3))
            else { return call.returnF64(-4) }
            let locale = call.string(call.i32(4), call.i32(5)) ?? ""
            let zone = call.string(call.i32(6), call.i32(7)) ?? ""
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = locale.isEmpty ? Locale(identifier: "en_US_POSIX") : Locale(identifier: locale)
            switch zone {
            case "", "current": formatter.timeZone = .current
            default: formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(abbreviation: zone) ?? .gmt
            }
            guard let date = formatter.date(from: string) else { return call.returnF64(-5) }
            call.returnF64(date.timeIntervalSince1970)
        }

        wasm.link("env", "print", "v(ii)") { [unowned self] call in
            let text = call.string(call.i32(0), call.i32(1)) ?? ""
            lastPrint = text
            log(text)
        }
        wasm.link("env", "abort", "v()") { _ in }
        wasm.link("env", "sleep", "v(i)") { call in
            Thread.sleep(forTimeInterval: TimeInterval(min(max(call.i32(0), 0), 30)))
        }
        // Partial results only make the first screen faster. Koma waits for the full result.
        wasm.link("env", "send_partial_result", "v(i)") { _ in }
    }

    // MARK: net

    private static let methods = ["GET", "POST", "PUT", "HEAD", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE"]

    private func request(_ descriptor: Int32) -> NetRequest? {
        guard case .request(let request)? = value(descriptor) else { return nil }
        return request
    }

    private func linkNet(_ wasm: WasmInstance) {
        wasm.link("net", "init", "i(i)") { [unowned self] call in
            let index = Int(call.i32(0))
            guard Self.methods.indices.contains(index) else { return call.returnI32(-3) }
            call.returnI32(add(.request(NetRequest(method: Self.methods[index]))))
        }

        wasm.link("net", "set_url", "i(iii)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let string = call.string(call.i32(1), call.i32(2)) else { return call.returnI32(-2) }
            guard let url = Self.makeURL(string), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else { return call.returnI32(-4) }
            request.request.url = url
            call.returnI32(0)
        }

        wasm.link("net", "set_header", "i(iiiii)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let key = call.string(call.i32(1), call.i32(2)),
                  let value = call.string(call.i32(3), call.i32(4))
            else { return call.returnI32(-2) }
            request.request.setValue(value, forHTTPHeaderField: key)
            call.returnI32(0)
        }

        wasm.link("net", "set_body", "i(iii)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let bytes = call.bytes(call.i32(1), call.i32(2)) else { return call.returnI32(-6) }
            request.request.httpBody = Data(bytes)
            call.returnI32(0)
        }

        wasm.link("net", "set_timeout", "i(iF)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            request.request.timeoutInterval = min(max(call.f64(1), 1), 120)
            call.returnI32(0)
        }

        wasm.link("net", "send", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            call.returnI32(send([request])[0])
        }

        wasm.link("net", "send_all", "i(ii)") { [unowned self] call in
            let pointer = call.i32(0)
            let count = Int(call.i32(1))
            guard count >= 0, count <= 256 else { return call.returnI32(-1) }
            var requests: [NetRequest?] = []
            for index in 0..<count {
                guard let descriptor = call.readI32(at: pointer + Int32(index * 4)) else { return call.returnI32(-11) }
                requests.append(request(descriptor))
            }
            let results = send(requests.compactMap { $0 })
            var iterator = results.makeIterator()
            var codes: [Int32] = requests.map { $0 == nil ? -1 : (iterator.next() ?? -10) }
            let failed = codes.contains { $0 != 0 }
            // The plugin reads the error codes back from the same array.
            let bytes = codes.withUnsafeMutableBytes { Array($0) }
            _ = call.write(bytes, to: pointer)
            call.returnI32(failed ? -1 : 0)
        }

        wasm.link("net", "data_len", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard request.response != nil || request.failed == false else { return call.returnI32(-8) }
            guard let data = request.responseData else { return call.returnI32(-7) }
            call.returnI32(Int32(clamping: data.count))
        }

        wasm.link("net", "read_data", "i(iii)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let data = request.responseData else { return call.returnI32(-7) }
            let length = Int(call.i32(2))
            guard length >= 0, length <= data.count else { return call.returnI32(-6) }
            call.returnI32(call.write([UInt8](data.prefix(length)), to: call.i32(1)) ? 0 : -11)
        }

        wasm.link("net", "get_image", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let data = request.responseData else { return call.returnI32(-7) }
            call.returnI32(add(.image(HostImage(data: data))))
        }

        wasm.link("net", "get_header", "i(iii)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let response = request.response else { return call.returnI32(-8) }
            guard let key = call.string(call.i32(1), call.i32(2)) else { return call.returnI32(-2) }
            guard let value = response.value(forHTTPHeaderField: key) else { return call.returnI32(-7) }
            call.returnI32(add(string: value))
        }

        wasm.link("net", "get_status_code", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let response = request.response else { return call.returnI32(-8) }
            call.returnI32(Int32(response.statusCode))
        }

        wasm.link("net", "get_url", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let url = request.response?.url ?? request.request.url else { return call.returnI32(-9) }
            call.returnI32(add(string: url.absoluteString))
        }

        wasm.link("net", "html", "i(i)") { [unowned self] call in
            guard let request = request(call.i32(0)) else { return call.returnI32(-1) }
            guard let data = request.responseData else { return call.returnI32(-7) }
            let html = Self.decodeText(data, response: request.response)
            let base = (request.response?.url ?? request.request.url)?.absoluteString ?? ""
            guard let document = try? SwiftSoup.parse(html, base) else { return call.returnI32(-5) }
            call.returnI32(add(.node(document)))
        }

        wasm.link("net", "set_rate_limit", "v(iii)") { [unowned self] call in
            let permits = Int(call.i32(0))
            let unit: TimeInterval = switch call.i32(2) { case 1: 60; case 2: 3600; default: 1 }
            let period = TimeInterval(call.i32(1)) * unit
            rateLimit = permits > 0 && period > 0 ? (permits, period) : nil
        }
    }

    /// Sends the requests at the same time and blocks until all finish.
    /// Returns 0 or an error code for each request.
    func send(_ requests: [NetRequest]) -> [Int32] {
        guard !requests.isEmpty else { return [] }
        let group = DispatchGroup()
        let codes = ErrorCodes(count: requests.count)
        for (index, request) in requests.enumerated() {
            guard request.request.url?.scheme?.hasPrefix("http") == true else {
                codes.set(-9, at: index)
                continue
            }
            waitForRateLimit()
            group.enter()
            let task = session.dataTask(with: request.request) { data, response, error in
                request.responseData = data
                request.response = response as? HTTPURLResponse
                if error != nil || response == nil {
                    request.failed = true
                    codes.set(-10, at: index)
                }
                group.leave()
            }
            task.resume()
        }
        group.wait()
        return codes.values
    }

    private final class ErrorCodes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int32]
        init(count: Int) { storage = Array(repeating: 0, count: count) }
        func set(_ code: Int32, at index: Int) { lock.withLock { storage[index] = code } }
        var values: [Int32] { lock.withLock { storage } }
    }

    private func waitForRateLimit() {
        guard let rateLimit else { return }
        let now = Date.now
        recentRequests.removeAll { now.timeIntervalSince($0) > rateLimit.period }
        if recentRequests.count >= rateLimit.permits, let oldest = recentRequests.first {
            let wait = rateLimit.period - now.timeIntervalSince(oldest)
            if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 30)) }
            recentRequests.removeFirst()
        }
        recentRequests.append(.now)
    }

    /// Accepts URLs with spaces or CJK characters, as browsers do.
    static func makeURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) { return url }
        return URL(string: trimmed, encodingInvalidCharacters: true)
    }

    static func decodeText(_ data: Data, response: HTTPURLResponse?) -> String {
        if let name = response?.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: defaults

    private func linkDefaults(_ wasm: WasmInstance) {
        wasm.link("defaults", "get", "i(ii)") { [unowned self] call in
            guard let key = call.string(call.i32(0), call.i32(1)) else { return call.returnI32(-1) }
            guard let bytes = defaults.get(key) else { return call.returnI32(-1) }
            call.returnI32(add(bytes: bytes))
        }

        // value points to an encoded result: [total length i32][capacity i32][postcard bytes].
        wasm.link("defaults", "set", "i(iiii)") { [unowned self] call in
            guard let key = call.string(call.i32(0), call.i32(1)) else { return call.returnI32(-1) }
            let kind = call.i32(2)
            let pointer = call.i32(3)
            if kind == 6 || pointer == 0 {
                defaults.set(key, nil)
                return call.returnI32(0)
            }
            guard let total = call.readI32(at: pointer), total >= 8,
                  let bytes = call.bytes(pointer + 8, total - 8)
            else { return call.returnI32(-2) }
            defaults.set(key, bytes)
            call.returnI32(0)
        }
    }
}
