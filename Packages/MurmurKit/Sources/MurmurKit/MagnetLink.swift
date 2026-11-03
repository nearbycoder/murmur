import Foundation

public enum MagnetError: LocalizedError, Equatable {
    case notAMagnet
    case missingInfoHash
    case v2Only

    public var errorDescription: String? {
        switch self {
        case .notAMagnet: "That isn't a magnet link."
        case .missingInfoHash: "The magnet link doesn't include a BitTorrent info hash."
        case .v2Only: "This magnet link is for a BitTorrent v2-only torrent, which Murmur can't download yet."
        }
    }
}

/// A `magnet:?xt=urn:btih:…` link (BEP 9).
public struct MagnetLink: Sendable, Equatable {
    public var infoHash: InfoHash
    public var displayName: String?
    public var trackers: [String]
    /// `x.pe` peer addresses to try directly.
    public var peers: [PeerAddress]
    /// `ws` web seed URLs (BEP 19).
    public var webSeeds: [String]

    public init(infoHash: InfoHash, displayName: String? = nil, trackers: [String] = [], peers: [PeerAddress] = [], webSeeds: [String] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
        self.peers = peers
        self.webSeeds = webSeeds
    }

    public init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:") else {
            // A bare info hash is accepted too.
            if let hash = InfoHash(string: trimmed) {
                self.init(infoHash: hash)
                return
            }
            throw MagnetError.notAMagnet
        }
        guard let q = trimmed.firstIndex(of: "?") else { throw MagnetError.missingInfoHash }
        let query = trimmed[trimmed.index(after: q)...]

        var hash: InfoHash?
        var sawV2 = false
        var name: String?
        var trackers: [String] = []
        var peers: [PeerAddress] = []
        var webSeeds: [String] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // Keys can carry an index (tr.1, xt.2).
            let key = parts[0].lowercased().split(separator: ".").first.map(String.init) ?? ""
            let rawValue = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = rawValue.removingPercentEncoding ?? rawValue
            switch key {
            case "xt":
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    hash = hash ?? InfoHash(string: String(value.dropFirst(9)))
                } else if lower.hasPrefix("urn:btmh:") {
                    sawV2 = true
                }
            case "dn":
                name = value
            case "ws":
                if !webSeeds.contains(value) { webSeeds.append(value) }
            case "tr":
                if !trackers.contains(value) { trackers.append(value) }
            case "x":
                if parts[0].lowercased() == "x.pe", let peer = PeerAddress(string: value) { peers.append(peer) }
            default:
                break
            }
        }
        guard let hash else { throw sawV2 ? MagnetError.v2Only : MagnetError.missingInfoHash }
        self.init(infoHash: hash, displayName: name, trackers: trackers, peers: peers, webSeeds: webSeeds)
    }

    public var uri: String {
        var s = "magnet:?xt=urn:btih:\(infoHash.hex)"
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        if let displayName, let encoded = displayName.addingPercentEncoding(withAllowedCharacters: allowed) {
            s += "&dn=\(encoded)"
        }
        for tracker in trackers {
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: allowed) { s += "&tr=\(encoded)" }
        }
        for peer in peers { s += "&x.pe=\(peer)" }
        for seed in webSeeds {
            if let encoded = seed.addingPercentEncoding(withAllowedCharacters: allowed) { s += "&ws=\(encoded)" }
        }
        return s
    }

    /// Finds the first magnet link (or bare info hash) in some text, such as the clipboard.
    public static func find(in text: String) -> MagnetLink? {
        if let range = text.range(of: #"magnet:\?[^\s"'<>]+"#, options: [.regularExpression, .caseInsensitive]),
           let link = try? MagnetLink(String(text[range])) {
            return link
        }
        return nil
    }
}
