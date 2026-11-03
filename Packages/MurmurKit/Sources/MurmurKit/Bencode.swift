import Foundation

/// A bencoded value (BEP 3): integers, byte strings, lists and dictionaries.
public enum BencodeValue: Equatable, Sendable {
    case integer(Int64)
    case bytes(Data)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])

    public init(_ string: String) { self = .bytes(Data(string.utf8)) }
    public init(_ int: Int) { self = .integer(Int64(int)) }

    public subscript(key: String) -> BencodeValue? {
        if case .dictionary(let dict) = self { return dict[key] }
        return nil
    }

    public var int: Int64? { if case .integer(let v) = self { return v }; return nil }
    public var data: Data? { if case .bytes(let v) = self { return v }; return nil }
    public var list: [BencodeValue]? { if case .list(let v) = self { return v }; return nil }
    public var dictionary: [String: BencodeValue]? { if case .dictionary(let v) = self { return v }; return nil }

    /// The byte string as UTF-8, falling back to Latin-1 so odd encodings still show something.
    public var string: String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        switch self {
        case .integer(let v):
            out.append(contentsOf: Array("i\(v)e".utf8))
        case .bytes(let d):
            out.append(contentsOf: Array("\(d.count):".utf8))
            out.append(d)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { item.encode(into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dictionary(let dict):
            out.append(UInt8(ascii: "d"))
            // Keys are sorted as raw byte strings.
            for key in dict.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                BencodeValue.bytes(Data(key.utf8)).encode(into: &out)
                dict[key]!.encode(into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

public enum BencodeError: Error, Equatable {
    case unexpectedEnd
    case invalidCharacter(at: Int)
    case invalidInteger(at: Int)
    case tooDeep
    case trailingData
}

/// Parses bencoded data. Records where the top-level `info` dictionary sits so its
/// exact bytes can be hashed into the info hash.
public struct BencodeDecoder {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    public private(set) var infoRange: Range<Int>?

    private static let maxDepth = 64

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// Decodes a single value that must span the whole input.
    public static func decode(_ data: Data) throws -> BencodeValue {
        var decoder = BencodeDecoder(data)
        let value = try decoder.decodeValue()
        guard decoder.index == decoder.bytes.count else { throw BencodeError.trailingData }
        return value
    }

    /// Decodes one value from the start of `data` and returns how many bytes it used,
    /// for messages that carry raw bytes after a dictionary (ut_metadata).
    public static func decodePrefix(_ data: Data) throws -> (BencodeValue, Int) {
        var decoder = BencodeDecoder(data)
        let value = try decoder.decodeValue()
        return (value, decoder.index)
    }

    public mutating func decodeValue() throws -> BencodeValue {
        guard index < bytes.count else { throw BencodeError.unexpectedEnd }
        switch bytes[index] {
        case UInt8(ascii: "i"):
            index += 1
            let value = try readInteger(until: UInt8(ascii: "e"))
            return .integer(value)
        case UInt8(ascii: "l"):
            index += 1
            depth += 1
            guard depth <= Self.maxDepth else { throw BencodeError.tooDeep }
            var items: [BencodeValue] = []
            while true {
                guard index < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                items.append(try decodeValue())
            }
            depth -= 1
            return .list(items)
        case UInt8(ascii: "d"):
            index += 1
            depth += 1
            guard depth <= Self.maxDepth else { throw BencodeError.tooDeep }
            var dict: [String: BencodeValue] = [:]
            while true {
                guard index < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                let keyData = try readBytes()
                let key = String(data: keyData, encoding: .utf8) ?? String(data: keyData, encoding: .isoLatin1) ?? ""
                let start = index
                let value = try decodeValue()
                if depth == 1 && key == "info" { infoRange = start..<index }
                dict[key] = value
            }
            depth -= 1
            return .dictionary(dict)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .bytes(try readBytes())
        default:
            throw BencodeError.invalidCharacter(at: index)
        }
    }

    private mutating func readInteger(until terminator: UInt8) throws -> Int64 {
        let start = index
        var negative = false
        var value: Int64 = 0
        var digits = 0
        if index < bytes.count && bytes[index] == UInt8(ascii: "-") { negative = true; index += 1 }
        while index < bytes.count && bytes[index] != terminator {
            let c = bytes[index]
            guard c >= 48 && c <= 57 else { throw BencodeError.invalidInteger(at: start) }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(c - 48))
            guard !o1 && !o2 else { throw BencodeError.invalidInteger(at: start) }
            value = a
            digits += 1
            index += 1
        }
        guard index < bytes.count else { throw BencodeError.unexpectedEnd }
        guard digits > 0 else { throw BencodeError.invalidInteger(at: start) }
        index += 1 // terminator
        return negative ? -value : value
    }

    private mutating func readBytes() throws -> Data {
        guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else {
            throw BencodeError.invalidCharacter(at: index)
        }
        let length = try readInteger(until: UInt8(ascii: ":"))
        guard length >= 0, length <= Int64(bytes.count - index) else { throw BencodeError.unexpectedEnd }
        let end = index + Int(length)
        let data = Data(bytes[index..<end])
        index = end
        return data
    }

    /// The raw bytes of the top-level `info` dictionary, if one was decoded.
    public func infoBytes() -> Data? {
        infoRange.map { Data(bytes[$0]) }
    }
}

extension Data {
    /// Appends a bencoded dictionary whose values are already encoded, so raw bytes
    /// (such as an info dictionary received over the wire) are kept exactly as they are.
    static func bencodedDictionary(_ entries: [String: Data]) -> Data {
        var out = Data([UInt8(ascii: "d")])
        for key in entries.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            BencodeValue(key).encode(into: &out)
            out.append(entries[key]!)
        }
        out.append(UInt8(ascii: "e"))
        return out
    }
}
