import Foundation
import CWasm3

nonisolated enum WasmError: LocalizedError {
    case parse(String)
    case missingFunction(String)
    case trap(String)
    case memory

    var errorDescription: String? {
        switch self {
        case .parse(let message): "The source could not be loaded (\(message))."
        case .missingFunction(let name): "The source has no function \"\(name)\"."
        case .trap(let message): "The source stopped with an error (\(message))."
        case .memory: "The source used memory that it does not own."
        }
    }
}

/// The arguments and the return slot of one call from the plugin to the host.
///
/// wasm3 gives raw functions a stack of 64-bit slots. If the function returns a
/// value, slot 0 is the return value and the arguments start at slot 1.
nonisolated struct WasmCall {
    fileprivate let stack: UnsafeMutablePointer<UInt64>
    fileprivate let argumentOffset: Int
    fileprivate let memoryBase: UnsafeMutableRawPointer?
    fileprivate let memorySize: UInt32

    func i32(_ index: Int) -> Int32 {
        UnsafeMutableRawPointer(stack + argumentOffset + index).load(as: Int32.self)
    }

    func f32(_ index: Int) -> Float {
        UnsafeMutableRawPointer(stack + argumentOffset + index).load(as: Float.self)
    }

    func f64(_ index: Int) -> Double {
        UnsafeMutableRawPointer(stack + argumentOffset + index).load(as: Double.self)
    }

    func bool(_ index: Int) -> Bool { i32(index) != 0 }

    // MARK: Linear memory

    private func range(_ pointer: Int32, _ length: Int32) -> UnsafeMutableRawPointer? {
        guard let memoryBase, pointer >= 0, length >= 0,
              UInt64(UInt32(pointer)) + UInt64(UInt32(length)) <= UInt64(memorySize)
        else { return nil }
        return memoryBase + Int(pointer)
    }

    func bytes(_ pointer: Int32, _ length: Int32) -> [UInt8]? {
        guard length > 0 else { return length == 0 ? [] : nil }
        guard let start = range(pointer, length) else { return nil }
        return Array(UnsafeRawBufferPointer(start: start, count: Int(length)))
    }

    /// A UTF-8 string from (pointer, length). nil if the range is invalid.
    func string(_ pointer: Int32, _ length: Int32) -> String? {
        guard let bytes = bytes(pointer, length) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    func write(_ bytes: [UInt8], to pointer: Int32) -> Bool {
        guard let start = range(pointer, Int32(clamping: bytes.count)) else { return false }
        bytes.withUnsafeBytes { start.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        return true
    }

    func readI32(at pointer: Int32) -> Int32? {
        guard let start = range(pointer, 4) else { return nil }
        return start.loadUnaligned(as: Int32.self)
    }

    // MARK: Return value

    func returnI32(_ value: Int32) {
        UnsafeMutableRawPointer(stack).storeBytes(of: value, as: Int32.self)
    }

    func returnI64(_ value: Int64) {
        UnsafeMutableRawPointer(stack).storeBytes(of: value, as: Int64.self)
    }

    func returnF32(_ value: Float) {
        UnsafeMutableRawPointer(stack).storeBytes(of: value, as: Float.self)
    }

    func returnF64(_ value: Double) {
        UnsafeMutableRawPointer(stack).storeBytes(of: value, as: Double.self)
    }
}

/// Swift closures cannot be C function pointers, so each import keeps its closure
/// in a box, and the box address is the wasm3 userdata.
nonisolated private final class ImportBox {
    let hasReturn: Bool
    let body: (WasmCall) -> Void

    init(hasReturn: Bool, body: @escaping (WasmCall) -> Void) {
        self.hasReturn = hasReturn
        self.body = body
    }
}

nonisolated private func rawImportHandler(
    runtime: IM3Runtime?,
    context: IM3ImportContext?,
    stack: UnsafeMutablePointer<UInt64>?,
    memory: UnsafeMutableRawPointer?
) -> UnsafeRawPointer? {
    guard let runtime, let stack, let userdata = koma_wasm3_userdata(context) else {
        return UnsafeRawPointer(m3Err_trapUnreachable)
    }
    let box = Unmanaged<ImportBox>.fromOpaque(userdata).takeUnretainedValue()
    let call = WasmCall(stack: stack, argumentOffset: box.hasReturn ? 1 : 0,
                        memoryBase: memory, memorySize: m3_GetMemorySize(runtime))
    box.body(call)
    return nil
}

/// One loaded WebAssembly module with its own runtime and memory.
/// Not thread safe: use it from one thread (SourceRunner's queue).
nonisolated final class WasmInstance {
    private let environment: IM3Environment
    private let runtime: IM3Runtime
    private let module: IM3Module
    private let bytes: [UInt8]   // wasm3 reads the module bytes while it runs.
    private var boxes: [ImportBox] = []
    private var functions: [String: IM3Function] = [:]

    /// Text that the plugin printed before an abort (panic message).
    var lastPrint: String?

    init(bytes: [UInt8], stackSize: UInt32 = 1 << 20) throws {
        guard let environment = m3_NewEnvironment() else { throw WasmError.parse("environment") }
        guard let runtime = m3_NewRuntime(environment, stackSize, nil) else {
            m3_FreeEnvironment(environment)
            throw WasmError.parse("runtime")
        }
        self.environment = environment
        self.runtime = runtime
        self.bytes = bytes

        var parsed: IM3Module?
        let parseResult = bytes.withUnsafeBufferPointer {
            m3_ParseModule(environment, &parsed, $0.baseAddress, UInt32($0.count))
        }
        if let parseResult {
            m3_FreeRuntime(runtime)
            m3_FreeEnvironment(environment)
            throw WasmError.parse(String(cString: parseResult))
        }
        guard let parsed else { throw WasmError.parse("module") }
        if let loadResult = m3_LoadModule(runtime, parsed) {
            m3_FreeModule(parsed)
            m3_FreeRuntime(runtime)
            m3_FreeEnvironment(environment)
            throw WasmError.parse(String(cString: loadResult))
        }
        module = parsed
    }

    deinit {
        // The runtime owns the loaded module.
        m3_FreeRuntime(runtime)
        m3_FreeEnvironment(environment)
    }

    /// Links a host function. `signature` uses wasm3 letters: "i(ii)" returns an
    /// i32 and takes two i32 values; v = void, I = i64, f = f32, F = f64.
    /// A function that the module does not import is skipped.
    func link(_ namespace: String, _ name: String, _ signature: String, _ body: @escaping (WasmCall) -> Void) {
        let box = ImportBox(hasReturn: !signature.hasPrefix("v"), body: body)
        let userdata = Unmanaged.passUnretained(box).toOpaque()
        let result = m3_LinkRawFunctionEx(module, namespace, name, signature, rawImportHandler, userdata)
        if result != m3Err_functionLookupFailed {
            boxes.append(box)
        }
    }

    func hasFunction(_ name: String) -> Bool {
        (try? function(name)) != nil
    }

    private func function(_ name: String) throws -> IM3Function {
        if let cached = functions[name] { return cached }
        var function: IM3Function?
        if let result = m3_FindFunction(&function, runtime, name) {
            throw WasmError.missingFunction("\(name): \(String(cString: result))")
        }
        guard let function else { throw WasmError.missingFunction(name) }
        functions[name] = function
        return function
    }

    /// Calls an exported function with i32 arguments.
    /// Returns its i32 result, or nil for a function with no result.
    @discardableResult
    func call(_ name: String, _ arguments: [Int32] = []) throws -> Int32? {
        let function = try function(name)
        var values = arguments
        let result: M3Result? = values.withUnsafeMutableBufferPointer { buffer in
            var pointers: [UnsafeRawPointer?] = (0..<buffer.count).map { UnsafeRawPointer(buffer.baseAddress! + $0) }
            return pointers.withUnsafeMutableBufferPointer {
                m3_Call(function, UInt32(arguments.count), $0.baseAddress)
            }
        }
        if let result {
            var info = M3ErrorInfo()
            m3_GetErrorInfo(runtime, &info)
            var message = String(cString: result)
            if let lastPrint, !lastPrint.isEmpty { message += ": " + lastPrint }
            throw WasmError.trap(message)
        }
        guard m3_GetRetCount(function) > 0 else { return nil }
        var output: Int32 = 0
        let getResult: M3Result? = withUnsafeMutablePointer(to: &output) { pointer in
            var pointers: [UnsafeRawPointer?] = [UnsafeRawPointer(pointer)]
            return pointers.withUnsafeMutableBufferPointer { m3_GetResults(function, 1, $0.baseAddress) }
        }
        if let getResult { throw WasmError.trap(String(cString: getResult)) }
        return output
    }

    // MARK: Memory (outside of an import call)

    private var memory: (base: UnsafeMutablePointer<UInt8>, size: UInt32)? {
        var size: UInt32 = 0
        guard let base = m3_GetMemory(runtime, &size, 0) else { return nil }
        return (base, size)
    }

    func readBytes(at pointer: Int32, count: Int) throws -> [UInt8] {
        guard let memory, pointer >= 0, count >= 0,
              UInt64(pointer) + UInt64(count) <= UInt64(memory.size)
        else { throw WasmError.memory }
        return Array(UnsafeBufferPointer(start: memory.base + Int(pointer), count: count))
    }

    func readI32(at pointer: Int32) throws -> Int32 {
        let bytes = try readBytes(at: pointer, count: 4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    }
}
