import Foundation

public enum MetainfoError: LocalizedError, Equatable {
    case notATorrent
    case missingField(String)
    case invalidField(String)
    case unsupportedV2Only

    public var errorDescription: String? {
        switch self {
        case .notATorrent: "This file isn't a valid torrent."
        case .missingField(let f): "The torrent is missing its “\(f)” field."
        case .invalidField(let f): "The torrent has an invalid “\(f)” field."
        case .unsupportedV2Only: "This torrent only supports BitTorrent v2, which Murmur can't download yet."
        }
    }
}

/// One file inside a torrent, with its byte offset in the torrent's concatenated data.
public struct TorrentFileEntry: Hashable, Sendable {
    /// Sanitized path components, relative to the torrent's folder.
    public let path: [String]
    public let length: Int64
    public let offset: Int64
    /// BEP 47 padding files only align pieces; they're never written to disk.
    public let isPadding: Bool

    public var relativePath: String { path.joined(separator: "/") }
    public var name: String { path.last ?? "" }
}

/// The parsed info dictionary: everything needed to download and verify the data.
public struct TorrentInfo: Sendable {
    public let infoHash: InfoHash
    public let name: String
    public let pieceLength: Int
    let pieceHashes: Data
    public let files: [TorrentFileEntry]
    public let totalLength: Int64
    public let isPrivate: Bool
    /// True when the files sit in a folder named after the torrent.
    public let isMultiFile: Bool
    /// The exact bencoded bytes, shared with peers over ut_metadata.
    public let rawInfo: Data

    public var pieceCount: Int { pieceHashes.count / 20 }

    public func pieceSize(_ index: Int) -> Int {
        if index == pieceCount - 1 {
            let rest = Int(totalLength - Int64(pieceLength) * Int64(pieceCount - 1))
            return rest
        }
        return pieceLength
    }

    func pieceHash(_ index: Int) -> Data {
        pieceHashes.subdata(in: pieceHashes.startIndex + index * 20 ..< pieceHashes.startIndex + index * 20 + 20)
    }

    public init(rawInfo: Data) throws {
        let value: BencodeValue
        do { value = try BencodeDecoder.decode(rawInfo) } catch { throw MetainfoError.notATorrent }
        guard case .dictionary = value else { throw MetainfoError.notATorrent }
        self.rawInfo = rawInfo
        infoHash = InfoHash.of(rawInfo)

        guard let pieceLength = value["piece length"]?.int, pieceLength > 0, pieceLength <= 1 << 28 else {
            throw value["piece length"] == nil ? MetainfoError.missingField("piece length") : MetainfoError.invalidField("piece length")
        }
        self.pieceLength = Int(pieceLength)

        guard let pieces = value["pieces"]?.data else {
            if value["file tree"] != nil { throw MetainfoError.unsupportedV2Only }
            throw MetainfoError.missingField("pieces")
        }
        guard pieces.count % 20 == 0, !pieces.isEmpty else { throw MetainfoError.invalidField("pieces") }
        pieceHashes = pieces

        let rawName = (value["name.utf-8"] ?? value["name"])?.string ?? ""
        let fallbackName = infoHash.hex
        name = TorrentInfo.sanitize(component: rawName) ?? fallbackName
        isPrivate = value["private"]?.int == 1

        var files: [TorrentFileEntry] = []
        var offset: Int64 = 0
        if let list = value["files"]?.list {
            isMultiFile = true
            var seen = Set<String>()
            for item in list {
                guard let length = item["length"]?.int, length >= 0 else { throw MetainfoError.invalidField("length") }
                let components = (item["path.utf-8"] ?? item["path"])?.list?.compactMap(\.string) ?? []
                var path = components.compactMap(TorrentInfo.sanitize(component:))
                if path.isEmpty { path = ["file \(files.count + 1)"] }
                // Two entries that sanitize to the same path would overwrite each other.
                var unique = path.joined(separator: "/")
                if seen.contains(unique.lowercased()) {
                    path[path.count - 1] = "\(files.count + 1) \(path[path.count - 1])"
                    unique = path.joined(separator: "/")
                }
                seen.insert(unique.lowercased())
                let attributes = item["attr"]?.string ?? ""
                files.append(TorrentFileEntry(path: path, length: length, offset: offset, isPadding: attributes.contains("p")))
                offset += length
            }
        } else if let length = value["length"]?.int, length >= 0 {
            isMultiFile = false
            files.append(TorrentFileEntry(path: [name], length: length, offset: 0, isPadding: false))
            offset = length
        } else {
            throw MetainfoError.missingField("length")
        }
        self.files = files
        totalLength = offset

        let expectedPieces = (offset + pieceLength - 1) / pieceLength
        guard Int64(pieces.count / 20) == expectedPieces, offset > 0 else { throw MetainfoError.invalidField("pieces") }
    }

    /// Makes one path component safe to use on disk: no traversal, separators or control characters.
    static func sanitize(component: String) -> String? {
        var s = component.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined()
        s = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.allSatisfy({ $0 == "." }) { return nil }
        // HFS+/APFS limit names to 255 bytes; keep the extension when shortening.
        if s.utf8.count > 255 {
            let ext = (s as NSString).pathExtension
            var stem = (s as NSString).deletingPathExtension
            while (stem + (ext.isEmpty ? "" : "." + ext)).utf8.count > 255 { stem.removeLast() }
            s = stem + (ext.isEmpty ? "" : "." + ext)
        }
        return s
    }
}

/// A .torrent file: the info dictionary plus trackers and descriptive fields.
public struct Metainfo: Sendable {
    public let info: TorrentInfo
    /// Tracker tiers (BEP 12). A plain `announce` becomes a single tier.
    public var trackers: [[String]]
    public var webSeeds: [String]
    public var comment: String?
    public var createdBy: String?
    public var creationDate: Date?

    public init(info: TorrentInfo, trackers: [[String]] = [], webSeeds: [String] = [], comment: String? = nil, createdBy: String? = nil, creationDate: Date? = nil) {
        self.info = info
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.comment = comment
        self.createdBy = createdBy
        self.creationDate = creationDate
    }

    public init(data: Data) throws {
        var decoder = BencodeDecoder(data)
        let value: BencodeValue
        do { value = try decoder.decodeValue() } catch { throw MetainfoError.notATorrent }
        guard case .dictionary = value, let infoBytes = decoder.infoBytes() else { throw MetainfoError.notATorrent }
        info = try TorrentInfo(rawInfo: infoBytes)

        var tiers: [[String]] = []
        if let list = value["announce-list"]?.list {
            for tier in list {
                let urls = tier.list?.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
                if !urls.isEmpty { tiers.append(urls) }
            }
        }
        if tiers.isEmpty, let announce = value["announce"]?.string?.trimmingCharacters(in: .whitespaces), !announce.isEmpty {
            tiers = [[announce]]
        }
        trackers = tiers
        if let list = value["url-list"]?.list {
            webSeeds = list.compactMap(\.string)
        } else if let single = value["url-list"]?.string, !single.isEmpty {
            webSeeds = [single]
        } else {
            webSeeds = []
        }
        comment = (value["comment.utf-8"] ?? value["comment"])?.string
        createdBy = value["created by"]?.string
        creationDate = value["creation date"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Re-encodes the torrent, keeping the info dictionary byte-for-byte.
    public func encoded() -> Data {
        var entries: [String: Data] = ["info": info.rawInfo]
        let flat = trackers.flatMap { $0 }
        if let first = flat.first { entries["announce"] = BencodeValue(first).encoded() }
        if !trackers.isEmpty {
            entries["announce-list"] = BencodeValue.list(trackers.map { .list($0.map(BencodeValue.init)) }).encoded()
        }
        if !webSeeds.isEmpty { entries["url-list"] = BencodeValue.list(webSeeds.map(BencodeValue.init)).encoded() }
        if let comment, !comment.isEmpty { entries["comment"] = BencodeValue(comment).encoded() }
        if let createdBy { entries["created by"] = BencodeValue(createdBy).encoded() }
        if let creationDate { entries["creation date"] = BencodeValue.integer(Int64(creationDate.timeIntervalSince1970)).encoded() }
        return Data.bencodedDictionary(entries)
    }

    public var magnetLink: MagnetLink {
        MagnetLink(infoHash: info.infoHash, displayName: info.name, trackers: trackers.flatMap { $0 }, peers: [])
    }
}
