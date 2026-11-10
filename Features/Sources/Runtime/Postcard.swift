import Foundation

/// The binary format that source plugins use for structured data (Rust `postcard`).
///
/// - Unsigned integers: LEB128 varints. Signed integers: zigzag, then varint.
/// - `u8`, `i8` and `bool`: one byte. `f32` / `f64`: little-endian IEEE bytes.
/// - String, list and map: varint count, then the items.
/// - Option: 0 = none, 1 = some + value. Enum: varint variant index, then the fields.
/// - Struct: the fields in order, with no names.
nonisolated struct PostcardWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    mutating func uint(_ value: Int) { varint(UInt64(max(0, value))) }

    mutating func int(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func i32(_ value: Int32) { int(Int64(value)) }

    mutating func f32(_ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func f64(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        uint(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    mutating func optional<T>(_ value: T?, _ write: (inout PostcardWriter, T) -> Void) {
        if let value {
            u8(1)
            write(&self, value)
        } else {
            u8(0)
        }
    }

    mutating func optionalString(_ value: String?) { optional(value) { $0.string($1) } }

    mutating func list<T>(_ values: [T], _ write: (inout PostcardWriter, T) -> Void) {
        uint(values.count)
        for value in values { write(&self, value) }
    }

    mutating func stringList(_ values: [String]) { list(values) { $0.string($1) } }

    mutating func stringMap(_ map: [String: String]) {
        uint(map.count)
        for (key, value) in map.sorted(by: { $0.key < $1.key }) {
            string(key)
            string(value)
        }
    }
}

nonisolated struct PostcardError: Error {}

nonisolated struct PostcardReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw PostcardError() }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bool() throws -> Bool { try u8() != 0 }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw PostcardError() }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func uint() throws -> Int {
        let value = try varint()
        guard value <= UInt64(Int32.max) else { throw PostcardError() }
        return Int(value)
    }

    mutating func int() throws -> Int64 {
        let raw = try varint()
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    mutating func f32() throws -> Float {
        guard offset + 4 <= bytes.count else { throw PostcardError() }
        var bits: UInt32 = 0
        for index in 0..<4 { bits |= UInt32(bytes[offset + index]) << (8 * UInt32(index)) }
        offset += 4
        return Float(bitPattern: bits)
    }

    mutating func f64() throws -> Double {
        guard offset + 8 <= bytes.count else { throw PostcardError() }
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        offset += 8
        return Double(bitPattern: bits)
    }

    mutating func string() throws -> String {
        let count = try uint()
        guard offset + count <= bytes.count else { throw PostcardError() }
        defer { offset += count }
        return String(decoding: bytes[offset..<offset + count], as: UTF8.self)
    }

    mutating func optional<T>(_ read: (inout PostcardReader) throws -> T) throws -> T? {
        switch try u8() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw PostcardError()
        }
    }

    mutating func optionalString() throws -> String? { try optional { try $0.string() } }

    mutating func list<T>(_ read: (inout PostcardReader) throws -> T) throws -> [T] {
        let count = try uint()
        // Each item is at least one byte, so a larger count is broken data.
        guard count <= bytes.count - offset else { throw PostcardError() }
        var values: [T] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try read(&self)) }
        return values
    }

    mutating func stringList() throws -> [String] { try list { try $0.string() } }

    mutating func stringMap() throws -> [String: String] {
        let count = try uint()
        guard count <= bytes.count - offset else { throw PostcardError() }
        var map: [String: String] = [:]
        for _ in 0..<count {
            let key = try string()
            map[key] = try string()
        }
        return map
    }
}
