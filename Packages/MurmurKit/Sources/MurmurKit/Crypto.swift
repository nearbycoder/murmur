import Foundation

/// RC4, as used by BitTorrent protocol encryption. (It's obfuscation against traffic shaping, not real security.)
struct RC4 {
    private var s = [UInt8](0...255)
    private var i: UInt8 = 0
    private var j: UInt8 = 0

    init(key: Data) {
        let k = [UInt8](key)
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ s[i] &+ k[i % k.count]
            s.swapAt(i, Int(j))
        }
    }

    /// MSE discards the first 1024 bytes of keystream.
    init(key: Data, discard: Int) {
        self.init(key: key)
        var scratch = [UInt8](repeating: 0, count: discard)
        process(&scratch)
    }

    mutating func process(_ bytes: inout [UInt8]) {
        for n in bytes.indices {
            i = i &+ 1
            j = j &+ s[Int(i)]
            s.swapAt(Int(i), Int(j))
            bytes[n] ^= s[Int(s[Int(i)] &+ s[Int(j)])]
        }
    }

    mutating func process(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        process(&bytes)
        return Data(bytes)
    }
}

/// Modular exponentiation for the 768-bit Diffie-Hellman exchange in MSE, using Montgomery
/// multiplication over 32-bit limbs (little-endian), so no division is needed.
struct Montgomery {
    let modulus: [UInt32]
    let n: Int
    private let inverse: UInt32
    private let r2: [UInt32]

    init(modulus bigEndian: Data) {
        let limbs = Montgomery.limbs(bigEndian)
        modulus = limbs
        n = limbs.count
        // -m^-1 mod 2^32 by Newton's iteration (m is odd).
        var x: UInt32 = 1
        for _ in 0..<5 { x = x &* (2 &- limbs[0] &* x) }
        inverse = 0 &- x
        // R^2 mod m, where R = 2^(32n): double 1 a total of 64n times, reducing as we go.
        var r = [UInt32](repeating: 0, count: limbs.count)
        r[0] = 1
        for _ in 0..<(64 * limbs.count) {
            var carry: UInt32 = 0
            for k in 0..<r.count {
                let v = r[k]
                r[k] = v << 1 | carry
                carry = v >> 31
            }
            if carry != 0 || !Montgomery.less(r, limbs) { Montgomery.subtract(&r, limbs) }
        }
        r2 = r
    }

    static func limbs(_ bigEndian: Data) -> [UInt32] {
        let bytes = [UInt8](bigEndian)
        let count = (bytes.count + 3) / 4
        var out = [UInt32](repeating: 0, count: count)
        for (index, byte) in bytes.reversed().enumerated() {
            out[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4))
        }
        return out
    }

    func bytes(_ limbs: [UInt32], length: Int) -> Data {
        var out = [UInt8](repeating: 0, count: length)
        for index in 0..<min(length, limbs.count * 4) {
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 4] >> (8 * UInt32(index % 4)))
        }
        return Data(out)
    }

    static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for k in stride(from: a.count - 1, through: 0, by: -1) where a[k] != b[k] { return a[k] < b[k] }
        return false
    }

    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for k in a.indices {
            let d = Int64(a[k]) - Int64(b[k]) - borrow
            a[k] = UInt32(truncatingIfNeeded: d)
            borrow = d < 0 ? 1 : 0
        }
    }

    /// a * b * R^-1 mod m (CIOS).
    func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0..<n {
            var c: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<n {
                let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                t[j] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            var s = UInt64(t[n]) + c
            t[n] = UInt32(truncatingIfNeeded: s)
            t[n + 1] = UInt32(truncatingIfNeeded: s >> 32)
            let m = UInt64(t[0] &* inverse)
            s = UInt64(t[0]) + m * UInt64(modulus[0])
            c = s >> 32
            for j in 1..<n {
                s = UInt64(t[j]) + m * UInt64(modulus[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            s = UInt64(t[n]) + c
            t[n - 1] = UInt32(truncatingIfNeeded: s)
            t[n] = t[n + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
            t[n + 1] = 0
        }
        var result = Array(t[0..<n])
        if t[n] != 0 || !Montgomery.less(result, modulus) { Montgomery.subtract(&result, modulus) }
        return result
    }

    /// base^exponent mod m, with big-endian byte strings in and out.
    func power(_ base: Data, _ exponent: Data) -> Data {
        var b = Montgomery.limbs(base)
        if b.count < n { b += [UInt32](repeating: 0, count: n - b.count) }
        b = Array(b.prefix(n))
        // Peers' values must be below the modulus; one subtraction is enough near 2^768.
        if !Montgomery.less(b, modulus) { Montgomery.subtract(&b, modulus) }
        let baseM = multiply(b, r2)
        var one = [UInt32](repeating: 0, count: n)
        one[0] = 1
        var result = multiply(one, r2)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = multiply(result, result)
                if byte >> UInt8(bit) & 1 == 1 { result = multiply(result, baseM) }
            }
        }
        return bytes(multiply(result, one), length: n * 4)
    }
}
