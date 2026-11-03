import Foundation

/// Makes .torrent files from a file or folder.
public enum TorrentCreator {
    public struct Options: Sendable {
        public var trackers: [[String]] = []
        public var webSeeds: [String] = []
        public var comment: String?
        public var isPrivate = false
        /// Bytes per piece; nil picks one for about 1,500 pieces.
        public var pieceLength: Int?
        public var source: String?
        public init() {}
    }

    public enum Error: LocalizedError {
        case empty
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .empty: "There's nothing to share: the selection has no files with data."
            case .cancelled: "Cancelled."
            }
        }
    }

    public static func suggestedPieceLength(for totalSize: Int64) -> Int {
        var length = 16 * 1024
        while length < 16 * 1024 * 1024 && totalSize / Int64(length) > 1500 { length *= 2 }
        return length
    }

    /// Hashes the content and returns the encoded torrent. `progress` is called from the calling thread.
    public static func create(from url: URL, options: Options = Options(), progress: ((Double) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> Data {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CocoaError(.fileNoSuchFile) }

        var files: [(url: URL, path: [String], length: Int64)] = []
        if isDirectory.boolValue {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isHiddenKey]
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let base = url.standardizedFileURL.pathComponents
            while let item = enumerator?.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let components = Array(item.standardizedFileURL.pathComponents.dropFirst(base.count))
                files.append((item, components, Int64(values.fileSize ?? 0)))
            }
            files.sort { $0.path.joined(separator: "/").localizedStandardCompare($1.path.joined(separator: "/")) == .orderedAscending }
        } else {
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            files = [(url, [url.lastPathComponent], size)]
        }
        let total = files.reduce(0) { $0 + $1.length }
        guard total > 0 else { throw Error.empty }

        let pieceLength = options.pieceLength ?? suggestedPieceLength(for: total)
        var hashes = Data()
        var buffer = Data(capacity: pieceLength)
        var processed: Int64 = 0
        for file in files where file.length > 0 {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            while true {
                if isCancelled() { throw Error.cancelled }
                let want = pieceLength - buffer.count
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
                buffer.append(chunk)
                processed += Int64(chunk.count)
                if buffer.count == pieceLength {
                    hashes.append(buffer.sha1())
                    buffer.removeAll(keepingCapacity: true)
                    progress?(Double(processed) / Double(total))
                }
            }
        }
        if !buffer.isEmpty { hashes.append(buffer.sha1()) }
        progress?(1)

        var info: [String: BencodeValue] = [
            "name": BencodeValue(url.lastPathComponent),
            "piece length": .integer(Int64(pieceLength)),
            "pieces": .bytes(hashes),
        ]
        if isDirectory.boolValue {
            info["files"] = .list(files.map { .dictionary(["length": .integer($0.length), "path": .list($0.path.map(BencodeValue.init))]) })
        } else {
            info["length"] = .integer(total)
        }
        if options.isPrivate { info["private"] = .integer(1) }
        if let source = options.source, !source.isEmpty { info["source"] = BencodeValue(source) }

        let parsed = try TorrentInfo(rawInfo: BencodeValue.dictionary(info).encoded())
        let meta = Metainfo(info: parsed, trackers: options.trackers.filter { !$0.isEmpty }, webSeeds: options.webSeeds,
                            comment: options.comment, createdBy: "Murmur \(PeerIdentity.clientVersion)", creationDate: Date())
        return meta.encoded()
    }
}
