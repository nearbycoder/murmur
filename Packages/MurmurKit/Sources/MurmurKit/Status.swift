import Foundation

public enum TorrentState: String, Codable, Sendable {
    case fetchingMetadata
    case checking
    case queued
    case downloading
    case seeding
    case paused
    /// Done and stopped: either it hit its seeding ratio or seeding is turned off.
    case finished
    case error
}

public enum FilePriority: Int, Codable, Sendable, CaseIterable, Identifiable {
    case skip = 0, low = 1, normal = 4, high = 7
    public var id: Int { rawValue }
}

public enum PeerSource: String, Codable, Sendable {
    case tracker, dht, pex, incoming, magnet, manual
}

public struct TorrentStatus: Identifiable, Sendable, Equatable {
    public let id: InfoHash
    public var name: String
    public var state: TorrentState
    /// Fraction of the wanted data that's downloaded and verified.
    public var progress: Double
    public var totalSize: Int64
    public var wantedSize: Int64
    public var completedSize: Int64
    public var downloadRate: Int64
    public var uploadRate: Int64
    public var downloaded: Int64
    public var uploaded: Int64
    public var ratio: Double
    public var eta: TimeInterval?
    public var connectedPeers: Int
    public var connectedSeeds: Int
    public var knownPeers: Int
    public var swarmSeeders: Int?
    public var swarmLeechers: Int?
    public var savePath: URL
    public var contentURL: URL?
    public var addedDate: Date
    public var completedDate: Date?
    public var errorMessage: String?
    public var checkingProgress: Double?
    public var isPrivate: Bool
    public var hasMetadata: Bool
    public var fileCount: Int
    public var isSequential: Bool
    public var queuePosition: Int
    public var magnetLink: String
    /// The extension of the largest file, for picking an icon.
    public var primaryFileExtension: String?
    public var isMultiFile: Bool
    public var ratioLimit: Double?

    public var isActive: Bool { state == .downloading || state == .seeding || state == .fetchingMetadata || state == .checking }
    public var isComplete: Bool { hasMetadata && completedSize >= wantedSize && wantedSize > 0 }

    public init(
        id: InfoHash,
        name: String,
        state: TorrentState,
        progress: Double,
        totalSize: Int64,
        wantedSize: Int64,
        completedSize: Int64,
        downloadRate: Int64,
        uploadRate: Int64,
        downloaded: Int64,
        uploaded: Int64,
        ratio: Double,
        eta: TimeInterval?,
        connectedPeers: Int,
        connectedSeeds: Int,
        knownPeers: Int,
        swarmSeeders: Int?,
        swarmLeechers: Int?,
        savePath: URL,
        contentURL: URL?,
        addedDate: Date,
        completedDate: Date?,
        errorMessage: String?,
        checkingProgress: Double?,
        isPrivate: Bool,
        hasMetadata: Bool,
        fileCount: Int,
        isSequential: Bool,
        queuePosition: Int,
        magnetLink: String,
        primaryFileExtension: String?,
        isMultiFile: Bool,
        ratioLimit: Double?
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.totalSize = totalSize
        self.wantedSize = wantedSize
        self.completedSize = completedSize
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.ratio = ratio
        self.eta = eta
        self.connectedPeers = connectedPeers
        self.connectedSeeds = connectedSeeds
        self.knownPeers = knownPeers
        self.swarmSeeders = swarmSeeders
        self.swarmLeechers = swarmLeechers
        self.savePath = savePath
        self.contentURL = contentURL
        self.addedDate = addedDate
        self.completedDate = completedDate
        self.errorMessage = errorMessage
        self.checkingProgress = checkingProgress
        self.isPrivate = isPrivate
        self.hasMetadata = hasMetadata
        self.fileCount = fileCount
        self.isSequential = isSequential
        self.queuePosition = queuePosition
        self.magnetLink = magnetLink
        self.primaryFileExtension = primaryFileExtension
        self.isMultiFile = isMultiFile
        self.ratioLimit = ratioLimit
    }
}

public struct FileStatus: Identifiable, Sendable, Equatable {
    public let id: Int
    public let path: String
    public let length: Int64
    public var downloaded: Int64
    public var priority: FilePriority
    public var progress: Double { length == 0 ? 1 : Double(downloaded) / Double(length) }

    public init(
        id: Int,
        path: String,
        length: Int64,
        downloaded: Int64,
        priority: FilePriority
    ) {
        self.id = id
        self.path = path
        self.length = length
        self.downloaded = downloaded
        self.priority = priority
    }
}

public struct PeerStatus: Identifiable, Sendable, Equatable {
    public var id: String { address.description }
    public let address: PeerAddress
    public let client: String
    public let progress: Double
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let downloaded: Int64
    public let uploaded: Int64
    public let isIncoming: Bool
    public let source: PeerSource
    /// qBittorrent-style flags: D/d downloading (or interested), U/u uploading, I incoming, X PEX, H DHT, S snubbed.
    public let flags: String

    public init(
        address: PeerAddress,
        client: String,
        progress: Double,
        downloadRate: Int64,
        uploadRate: Int64,
        downloaded: Int64,
        uploaded: Int64,
        isIncoming: Bool,
        source: PeerSource,
        flags: String
    ) {
        self.address = address
        self.client = client
        self.progress = progress
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.isIncoming = isIncoming
        self.source = source
        self.flags = flags
    }
}

public struct TrackerStatus: Identifiable, Sendable, Equatable {
    public var id: String { url }
    public let url: String
    public let tier: Int
    public let status: String
    public let message: String?
    public let seeders: Int?
    public let leechers: Int?
    public let peers: Int
    public let lastAnnounce: Date?
    public let nextAnnounce: Date?

    public init(
        url: String,
        tier: Int,
        status: String,
        message: String?,
        seeders: Int?,
        leechers: Int?,
        peers: Int,
        lastAnnounce: Date?,
        nextAnnounce: Date?
    ) {
        self.url = url
        self.tier = tier
        self.status = status
        self.message = message
        self.seeders = seeders
        self.leechers = leechers
        self.peers = peers
        self.lastAnnounce = lastAnnounce
        self.nextAnnounce = nextAnnounce
    }
}

public struct TorrentDetails: Sendable, Equatable {
    public let id: InfoHash
    public var files: [FileStatus]
    public var peers: [PeerStatus]
    public var trackers: [TrackerStatus]
    /// Downsampled piece completion (0…1) for drawing a piece map.
    public var pieceMap: [Float]
    public var pieceCount: Int
    public var pieceLength: Int
    public var comment: String?
    public var createdBy: String?
    public var creationDate: Date?
    public var webSeeds: [String]

    public init(
        id: InfoHash,
        files: [FileStatus],
        peers: [PeerStatus],
        trackers: [TrackerStatus],
        pieceMap: [Float],
        pieceCount: Int,
        pieceLength: Int,
        comment: String?,
        createdBy: String?,
        creationDate: Date?,
        webSeeds: [String]
    ) {
        self.id = id
        self.files = files
        self.peers = peers
        self.trackers = trackers
        self.pieceMap = pieceMap
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.comment = comment
        self.createdBy = createdBy
        self.creationDate = creationDate
        self.webSeeds = webSeeds
    }
}

public struct SessionStats: Sendable, Equatable {
    public var downloadRate: Int64 = 0
    public var uploadRate: Int64 = 0
    public var sessionDownloaded: Int64 = 0
    public var sessionUploaded: Int64 = 0
    public var dhtNodes = 0
    public var connectedPeers = 0
    public var listenPort: UInt16 = 0
    public var incomingConnections = 0
    public var portMapping: String?
    public var isListening = false
    public init() {}
}

public enum SessionEvent: Sendable {
    case finished(InfoHash, name: String)
    case metadataReceived(InfoHash, name: String)
    case failed(InfoHash, name: String, message: String)
}
