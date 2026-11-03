import CryptoKit
import Foundation

/// The 20-byte SHA-1 of a torrent's info dictionary, which identifies it everywhere.
public struct InfoHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = Data(bytes)
    }

    /// Accepts 40 hex characters or 32 base32 characters, as magnet links use both.
    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        if s.count == 40, let data = Data(hex: s) {
            self.bytes = data
        } else if s.count == 32, let data = Data(base32: s), data.count == 20 {
            self.bytes = data
        } else {
            return nil
        }
    }

    public static func of(_ data: Data) -> InfoHash {
        InfoHash(bytes: data.sha1())!
    }

    public var hex: String { bytes.hexString }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let hash = InfoHash(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid info hash")
        }
        self = hash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension Data {
    func sha1() -> Data { Data(Insecure.SHA1.hash(data: self)) }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    init?(base32: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var lookup = [UInt8: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for c in base32.uppercased().utf8 where c != UInt8(ascii: "=") {
            guard let v = lookup[c] else { return nil }
            buffer = buffer << 5 | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        self = out
    }

    /// Percent-encodes every byte that isn't unreserved, for tracker query strings.
    var urlPercentEncoded: String {
        var s = ""
        for b in self {
            switch b {
            case 48...57, 65...90, 97...122, 45, 46, 95, 126:
                s.append(Character(UnicodeScalar(b)))
            default:
                s += String(format: "%%%02X", b)
            }
        }
        return s
    }
}

/// Builds our peer id (Azureus style, `-MU1000-` plus 12 random characters) and names
/// other clients from theirs.
public enum PeerIdentity {
    public static let clientVersion = "1.0.0"
    static let prefix = "-MU1000-"

    public static func generate() -> Data {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var id = Data(prefix.utf8)
        for _ in 0..<12 { id.append(alphabet.randomElement()!) }
        return id
    }

    private static let azureus: [String: String] = [
        "7T": "aTorrent", "AG": "Ares", "AZ": "Vuze", "BC": "BitComet", "BI": "BiglyBT", "BT": "BitTorrent",
        "BW": "BitWombat", "DE": "Deluge", "FD": "Free Download Manager", "FW": "FrostWire", "FX": "Freebox",
        "HL": "Halite", "KT": "KTorrent", "LT": "libtorrent", "lt": "libTorrent", "MU": "Murmur", "PI": "PicoTorrent",
        "qB": "qBittorrent", "RT": "rTorrent", "SD": "Thunder", "TL": "Tribler", "TR": "Transmission",
        "TT": "TuoTu", "UM": "µTorrent Mac", "UT": "µTorrent", "UW": "µTorrent Web", "WD": "WebTorrent Desktop",
        "WW": "WebTorrent", "XL": "Xunlei", "BN": "Baidu Netdisk", "FL": "Folx", "TX": "Tixati", "ZO": "Zona",
        "AR": "Arctic", "EB": "EBit", "XF": "Xfplay", "GR": "GetRight", "SZ": "Shareaza", "NE": "BT Next Evolution",
        "IL": "iLivid", "BF": "Bitflu", "FG": "FlashGet", "OS": "OneSwarm", "PD": "Pando", "QD": "QQDownload",
        "SP": "BitSpirit", "ST": "SymTorrent", "XT": "XanTorrent", "XX": "Xtorrent", "LW": "LimeWire",
        "BB": "BitBuddy", "MG": "MediaGet", "TS": "Torrentstorm", "VG": "Vagaa", "ML": "MLDonkey",
    ]

    /// A readable client name and version from a peer id, or nil when it's unrecognized.
    public static func clientName(for peerID: Data) -> String? {
        let b = [UInt8](peerID)
        guard b.count == 20 else { return nil }
        func ascii(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }
        if b[0] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") {
            let code = ascii(1..<3)
            let name = azureus[code] ?? code
            let v = b[3..<7].map { c -> String in
                if c >= 48 && c <= 57 { return String(c - 48) }
                if c >= 65 && c <= 90 { return String(Int(c) - 55) }
                if c >= 97 && c <= 122 { return String(Int(c) - 61) }
                return ""
            }
            if code == "TR" {
                // Transmission: -TR4060- is 4.06, -TR300Z- is 3.00 (dev).
                let digits = ascii(3..<6)
                if let n = Int(digits) { return "Transmission \(n / 100).\(String(format: "%02d", n % 100))" }
            }
            let version = v.prefix(3).joined(separator: ".")
            return "\(name) \(version)"
        }
        if b.starts(with: Array("A2-".utf8)) {
            let parts = ascii(3..<20).split(separator: "-").prefix(3).joined(separator: ".")
            return "aria2 \(parts)"
        }
        if b[0] == UInt8(ascii: "M"), b[2] == UInt8(ascii: "-") || b[3] == UInt8(ascii: "-") {
            return "BitTorrent (mainline)"
        }
        if b.starts(with: Array("-WS".utf8)) { return "HTTP seed" }
        let shadow: [UInt8: String] = [UInt8(ascii: "A"): "ABC", UInt8(ascii: "O"): "Osprey", UInt8(ascii: "S"): "Shadow", UInt8(ascii: "T"): "BitTornado"]
        if let name = shadow[b[0]], b[5] == UInt8(ascii: "-") || b[4] == UInt8(ascii: "-") { return name }
        return nil
    }
}
