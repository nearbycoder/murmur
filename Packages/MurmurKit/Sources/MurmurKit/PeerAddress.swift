import Foundation
import Network

/// An IP address and port for a peer, from a tracker, DHT, PEX, a magnet or an incoming connection.
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible, Codable {
    /// An IPv4 or IPv6 literal.
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parses `1.2.3.4:6881` or `[::1]:6881`.
    public init?(string: String) {
        if string.hasPrefix("["), let close = string.firstIndex(of: "]") {
            let host = String(string[string.index(after: string.startIndex)..<close])
            let rest = string[string.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), IPv6Address(host) != nil else { return nil }
            self.init(host: host, port: port)
        } else {
            let parts = string.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]), IPv4Address(String(parts[0])) != nil else { return nil }
            self.init(host: String(parts[0]), port: port)
        }
    }

    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
    public var isIPv6: Bool { host.contains(":") }

    var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 6881)
    }

    var isUsable: Bool {
        guard port != 0 else { return false }
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return !(b[0] == 0 || b[0] >= 224 || (b[0] == 255))
        }
        return IPv6Address(host) != nil
    }

    var isLocal: Bool {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 169 && b[1] == 254)
        }
        return host == "::1" || host.lowercased().hasPrefix("fe80") || host.lowercased().hasPrefix("fd")
    }

    /// 6 bytes for IPv4 or 18 for IPv6, network byte order.
    var compact: Data? {
        var out = Data()
        if let v4 = IPv4Address(host) {
            out.append(v4.rawValue)
        } else if let v6 = IPv6Address(host) {
            out.append(v6.rawValue)
        } else {
            return nil
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    static func parseCompact(_ data: Data, ipv6: Bool = false) -> [PeerAddress] {
        let stride = ipv6 ? 18 : 6
        let bytes = [UInt8](data)
        var out: [PeerAddress] = []
        var i = 0
        while i + stride <= bytes.count {
            let ipBytes = Data(bytes[i..<i + stride - 2])
            let port = UInt16(bytes[i + stride - 2]) << 8 | UInt16(bytes[i + stride - 1])
            let host: String? = ipv6 ? IPv6Address(ipBytes).map { "\($0)" } : IPv4Address(ipBytes).map { "\($0)" }
            if let host {
                let address = PeerAddress(host: host, port: port)
                if address.isUsable { out.append(address) }
            }
            i += stride
        }
        return out
    }

    /// Builds an address from a connection's remote endpoint (incoming peers).
    init?(endpoint: NWEndpoint) {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        var hostString: String
        switch host {
        case .ipv4(let a): hostString = "\(a)"
        case .ipv6(let a): hostString = "\(a)"
        case .name(let n, _): hostString = n
        @unknown default: return nil
        }
        // Strip interface scopes (fe80::1%en0) and IPv4-mapped prefixes.
        if let percent = hostString.firstIndex(of: "%") { hostString = String(hostString[..<percent]) }
        if hostString.lowercased().hasPrefix("::ffff:"), IPv4Address(String(hostString.dropFirst(7))) != nil {
            hostString = String(hostString.dropFirst(7))
        }
        self.init(host: hostString, port: port.rawValue)
    }
}
