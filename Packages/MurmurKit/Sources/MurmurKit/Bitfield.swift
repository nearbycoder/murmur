import Foundation

/// A fixed-length set of bits, high bit first, as the peer wire protocol sends them.
public struct Bitfield: Equatable, Sendable {
    public private(set) var bytes: [UInt8]
    public let count: Int
    public private(set) var cardinality = 0

    public init(count: Int, filled: Bool = false) {
        self.count = count
        bytes = [UInt8](repeating: filled ? 0xFF : 0, count: (count + 7) / 8)
        if filled {
            clearSpareBits()
            cardinality = count
        }
    }

    /// Fails when the length is wrong or spare bits at the end are set.
    public init?(data: Data, count: Int) {
        guard data.count == (count + 7) / 8 else { return nil }
        self.count = count
        bytes = [UInt8](data)
        let spare = bytes.count * 8 - count
        if spare > 0, let last = bytes.last, last & UInt8((1 << spare) - 1) != 0 { return nil }
        cardinality = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    public subscript(index: Int) -> Bool {
        get { bytes[index >> 3] & (0x80 >> UInt8(index & 7)) != 0 }
        set {
            let mask: UInt8 = 0x80 >> UInt8(index & 7)
            let old = bytes[index >> 3] & mask != 0
            guard old != newValue else { return }
            if newValue { bytes[index >> 3] |= mask; cardinality += 1 } else { bytes[index >> 3] &= ~mask; cardinality -= 1 }
        }
    }

    public var isFull: Bool { cardinality == count }
    public var isEmpty: Bool { cardinality == 0 }
    public var data: Data { Data(bytes) }
    public var fraction: Double { count == 0 ? 0 : Double(cardinality) / Double(count) }

    private mutating func clearSpareBits() {
        let spare = bytes.count * 8 - count
        if spare > 0 { bytes[bytes.count - 1] &= ~UInt8((1 << spare) - 1) }
    }
}
