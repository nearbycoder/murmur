import Foundation

/// The standard block size every client requests.
let blockSize = 16 * 1024

struct BlockRequest: Hashable {
    let piece: Int
    let begin: Int
    let length: Int
}

struct Handshake {
    static let protocolName = Data("BitTorrent protocol".utf8)

    let reserved: Data
    let infoHash: InfoHash
    let peerID: Data

    var supportsExtensions: Bool { reserved[reserved.startIndex + 5] & 0x10 != 0 }
    var supportsDHT: Bool { reserved[reserved.startIndex + 7] & 0x01 != 0 }

    /// Our reserved bits: the extension protocol (BEP 10) and DHT (BEP 5).
    static func ours(dht: Bool) -> Data {
        var reserved = Data(count: 8)
        reserved[5] |= 0x10
        if dht { reserved[7] |= 0x01 }
        return reserved
    }

    func encoded() -> Data {
        var out = Data([19])
        out.append(Handshake.protocolName)
        out.append(reserved)
        out.append(infoHash.bytes)
        out.append(peerID)
        return out
    }

    static func parse(_ bytes: Data) -> Handshake? {
        guard bytes.count >= 68 else { return nil }
        let b = bytes.startIndex
        guard bytes[b] == 19, bytes.subdata(in: b + 1 ..< b + 20) == protocolName else { return nil }
        guard let hash = InfoHash(bytes: bytes.subdata(in: b + 28 ..< b + 48)) else { return nil }
        return Handshake(reserved: bytes.subdata(in: b + 20 ..< b + 28), infoHash: hash, peerID: bytes.subdata(in: b + 48 ..< b + 68))
    }
}

enum PeerMessage {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(Int)
    case bitfield(Data)
    case request(BlockRequest)
    case piece(index: Int, begin: Int, block: Data)
    case cancel(BlockRequest)
    case port(UInt16)
    case extended(id: UInt8, payload: Data)
    case unknown(UInt8)

    /// The largest message we accept: a block plus header, or a big bitfield or metadata piece.
    static let maxLength = 2 * 1024 * 1024

    func encoded() -> Data {
        var out = Data()
        func header(_ length: Int, _ id: UInt8) {
            out.appendUInt32(UInt32(length))
            out.append(id)
        }
        switch self {
        case .keepAlive: out.appendUInt32(0)
        case .choke: header(1, 0)
        case .unchoke: header(1, 1)
        case .interested: header(1, 2)
        case .notInterested: header(1, 3)
        case .have(let index):
            header(5, 4); out.appendUInt32(UInt32(index))
        case .bitfield(let bits):
            header(1 + bits.count, 5); out.append(bits)
        case .request(let r):
            header(13, 6); out.appendUInt32(UInt32(r.piece)); out.appendUInt32(UInt32(r.begin)); out.appendUInt32(UInt32(r.length))
        case .piece(let index, let begin, let block):
            out.reserveCapacity(13 + block.count)
            header(9 + block.count, 7); out.appendUInt32(UInt32(index)); out.appendUInt32(UInt32(begin)); out.append(block)
        case .cancel(let r):
            header(13, 8); out.appendUInt32(UInt32(r.piece)); out.appendUInt32(UInt32(r.begin)); out.appendUInt32(UInt32(r.length))
        case .port(let port):
            header(3, 9); out.append(UInt8(port >> 8)); out.append(UInt8(port & 0xFF))
        case .extended(let id, let payload):
            header(2 + payload.count, 20); out.append(id); out.append(payload)
        case .unknown(let id):
            header(1, id)
        }
        return out
    }

    /// Decodes a message body (without the length prefix). Nil means it's malformed.
    static func decode(_ body: Data) -> PeerMessage? {
        guard let id = body.first else { return .keepAlive }
        let p = body.dropFirst()
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            guard p.count == 4 else { return nil }
            return .have(Int(p.uint32(at: 0)))
        case 5: return .bitfield(Data(p))
        case 6, 8:
            guard p.count == 12 else { return nil }
            let r = BlockRequest(piece: Int(p.uint32(at: 0)), begin: Int(p.uint32(at: 4)), length: Int(p.uint32(at: 8)))
            return id == 6 ? .request(r) : .cancel(r)
        case 7:
            guard p.count >= 8 else { return nil }
            return .piece(index: Int(p.uint32(at: 0)), begin: Int(p.uint32(at: 4)), block: Data(p.dropFirst(8)))
        case 9:
            guard p.count == 2 else { return nil }
            return .port(UInt16(p[p.startIndex]) << 8 | UInt16(p[p.startIndex + 1]))
        case 20:
            guard let ext = p.first else { return nil }
            return .extended(id: ext, payload: Data(p.dropFirst()))
        default:
            return .unknown(id)
        }
    }
}

extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xFF))
    }

    mutating func appendUInt64(_ v: UInt64) {
        appendUInt32(UInt32(v >> 32)); appendUInt32(UInt32(v & 0xFFFF_FFFF))
    }
}

extension DataProtocol where Index == Int {
    /// Reads a big-endian UInt32 at an offset from the start of this (possibly sliced) data.
    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) << 32 | UInt64(uint32(at: offset + 4))
    }
}
