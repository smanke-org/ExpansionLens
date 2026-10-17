import Foundation

/// Decodes values that WebKit stored in an IndexedDB database (its structured-clone
/// serialization), as far as plain data goes: objects, arrays, strings, numbers, booleans,
/// dates and null. That's all a snippet library holds.
public struct WebKitValueDecoder {
    public enum DecodeError: Error, Equatable { case truncated, unsupportedTag(UInt8), badVersion }

    private let bytes: [UInt8]
    private var pos = 0
    private var pool: [String] = []

    private static let terminator: UInt32 = 0xFFFF_FFFF
    private static let poolReference: UInt32 = 0xFFFF_FFFE

    public init(_ data: Data) { bytes = [UInt8](data) }

    public static func decode(_ data: Data) throws -> Any? {
        var decoder = WebKitValueDecoder(data)
        return try decoder.decodeRoot()
    }

    mutating func decodeRoot() throws -> Any? {
        let version = try u32()
        guard version > 0, version < 64 else { throw DecodeError.badVersion }
        return try value()
    }

    private mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw DecodeError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func u16() throws -> UInt16 {
        guard pos + 2 <= bytes.count else { throw DecodeError.truncated }
        defer { pos += 2 }
        return UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
    }

    private mutating func u32() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw DecodeError.truncated }
        defer { pos += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[pos + $1]) << (8 * UInt32($1)) }
    }

    private mutating func f64() throws -> Double {
        guard pos + 8 <= bytes.count else { throw DecodeError.truncated }
        var raw: UInt64 = 0
        for i in 0..<8 { raw |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return Double(bitPattern: raw)
    }

    private mutating func poolIndex() throws -> Int {
        // The index is as wide as the pool needs.
        if pool.count <= 0xFF { return Int(try u8()) }
        if pool.count <= 0xFFFF { return Int(try u16()) }
        return Int(try u32())
    }

    /// A string whose length word was already read (property names), or read here.
    private mutating func string(length known: UInt32? = nil) throws -> String {
        let word = try known ?? u32()
        if word == Self.poolReference {
            let index = try poolIndex()
            guard pool.indices.contains(index) else { throw DecodeError.truncated }
            return pool[index]
        }
        let is8Bit = word & 0x8000_0000 != 0
        let length = Int(word & 0x7FFF_FFFF)
        let s: String
        if is8Bit {
            guard pos + length <= bytes.count else { throw DecodeError.truncated }
            s = String(decoding: bytes[pos..<pos + length].map { UInt16($0) }, as: UTF16.self)
            pos += length
        } else {
            guard pos + 2 * length <= bytes.count else { throw DecodeError.truncated }
            var units: [UInt16] = []
            units.reserveCapacity(length)
            for i in 0..<length { units.append(UInt16(bytes[pos + 2 * i]) | UInt16(bytes[pos + 2 * i + 1]) << 8) }
            pos += 2 * length
            s = String(decoding: units, as: UTF16.self)
        }
        pool.append(s)
        return s
    }

    private mutating func properties(into dict: inout [String: Any]) throws {
        while true {
            let word = try u32()
            if word == Self.terminator { return }
            let key = try string(length: word)
            dict[key] = try value() ?? NSNull()
        }
    }

    private mutating func value() throws -> Any? {
        let tag = try u8()
        switch tag {
        case 1: // array
            let count = Int(try u32())
            var array = [Any](repeating: NSNull(), count: count)
            while true {
                let index = try u32()
                if index == Self.terminator { break }
                let v = try value() ?? NSNull()
                if Int(index) < count { array[Int(index)] = v }
            }
            var extra: [String: Any] = [:]
            try properties(into: &extra)
            return array
        case 2: // object
            var dict: [String: Any] = [:]
            try properties(into: &dict)
            return dict
        case 3, 4: return nil // undefined, null
        case 5: return Int(Int32(bitPattern: try u32()))
        case 6: return 0
        case 7: return 1
        case 8: return false
        case 9: return true
        case 10: return try f64()
        case 11: return Date(timeIntervalSince1970: try f64() / 1000)
        case 16: return try string()
        case 17: return ""
        default: throw DecodeError.unsupportedTag(tag)
        }
    }
}
