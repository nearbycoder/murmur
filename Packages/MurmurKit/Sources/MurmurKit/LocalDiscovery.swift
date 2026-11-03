import Foundation

/// Local Service Discovery (BEP 14): announces torrents to the local network over multicast,
/// so peers on the same LAN find each other without the internet in between.
final class LocalDiscovery {
    private static let group: UInt32 = 0xEFC0_988F // 239.192.152.143
    private static let port: UInt16 = 6771
    private let socket: UDPSocket
    private let cookie = String(UInt32.random(in: 1...UInt32.max), radix: 16)
    var onPeer: ((InfoHash, PeerAddress) -> Void)?

    init(queue: DispatchQueue) throws {
        socket = try UDPSocket(port: LocalDiscovery.port, queue: queue, multicastGroup: LocalDiscovery.group)
        socket.onPacket = { [weak self] data, from in self?.handle(data, from: from) }
    }

    func stop() { socket.close() }

    /// Announces up to a handful of torrents per packet, as the spec suggests.
    func announce(_ hashes: [InfoHash], port: UInt16) {
        for chunk in stride(from: 0, to: hashes.count, by: 8).map({ Array(hashes[$0 ..< min($0 + 8, hashes.count)]) }) {
            var message = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: \(port)\r\n"
            for hash in chunk { message += "Infohash: \(hash.hex)\r\n" }
            message += "cookie: \(cookie)\r\n\r\n\r\n"
            socket.send(Data(message.utf8), to: NodeEndpoint(ip: LocalDiscovery.group, port: LocalDiscovery.port))
        }
    }

    private func handle(_ data: Data, from: NodeEndpoint) {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("BT-SEARCH") else { return }
        var port: UInt16?
        var hashes: [InfoHash] = []
        var theirCookie: String?
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "port": port = UInt16(parts[1])
            case "infohash": if let hash = InfoHash(string: parts[1]) { hashes.append(hash) }
            case "cookie": theirCookie = parts[1]
            default: break
            }
        }
        guard theirCookie != cookie, let port, port > 0 else { return }
        let peer = PeerAddress(host: from.peerAddress.host, port: port)
        for hash in hashes { onPeer?(hash, peer) }
    }
}
