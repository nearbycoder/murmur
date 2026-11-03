import Foundation

/// One connected (or connecting) peer of a torrent and our view of its state.
final class Peer {
    let connection: PeerConnection
    var address: PeerAddress
    let source: PeerSource
    let connectedAt = Date()

    var handshaken = false
    var peerID: Data?
    var client: String?
    var supportsExtensions = false
    var supportsDHT = false

    var bitfield: Bitfield?
    /// A bitfield or haves that arrived before we had the metadata to size them.
    var pendingBitfield: Data?
    var pendingHaves: [Int] = []
    var hasAll = false

    var amChoking = true
    var amInterested = false
    var peerChoking = true
    var peerInterested = false

    /// Blocks we've asked this peer for.
    var requests: [BlockRequest: Date] = [:]
    /// Blocks this peer has asked us for.
    var incoming: [BlockRequest] = []
    var isServing = false

    /// The peer's extension message ids (BEP 10).
    var extensions: [String: UInt8] = [:]
    var metadataSize: Int?
    var listenPort: UInt16?
    var maxRequests = 250
    var metadataRequests: [Int: Date] = [:]
    /// The picker generation at which no new piece was found for this peer.
    var pickMissGeneration = -1

    var download = RateMeter()
    var upload = RateMeter()
    var lastBlockReceived = Date.distantPast
    var lastUnchoked = Date.distantPast
    var snubbed = false
    var hashFailures = 0
    var pexSent: Set<PeerAddress> = []
    var lastPex = Date()

    init(connection: PeerConnection, address: PeerAddress, source: PeerSource) {
        self.connection = connection
        self.address = address
        self.source = source
    }

    var isSeed: Bool { hasAll || (bitfield?.isFull ?? false) }

    /// The address other peers can reach this one at, for PEX.
    var reachableAddress: PeerAddress? {
        if !connection.isIncoming { return address }
        if let listenPort, listenPort > 0 { return PeerAddress(host: address.host, port: listenPort) }
        return nil
    }

    /// How many requests to keep in flight: roughly two seconds of data at its current speed.
    var pipelineTarget: Int {
        let perSecond = Int(download.rate) / blockSize
        return min(max(perSecond * 2 + 8, 16), max(min(maxRequests, 400), 16))
    }

    func has(_ piece: Int) -> Bool { hasAll || (bitfield?[piece] ?? false) }
}

/// A piece being downloaded: its blocks and who has been asked for them.
final class PieceDownload {
    enum BlockState { case missing, requested, received }

    let index: Int
    let size: Int
    var data: Data
    var blocks: [BlockState]
    var requesters: [[ObjectIdentifier]]
    var receivedCount = 0
    var contributors = Set<String>()
    let started = Date()

    init(index: Int, size: Int) {
        self.index = index
        self.size = size
        data = Data(count: size)
        let count = (size + blockSize - 1) / blockSize
        blocks = Array(repeating: .missing, count: count)
        requesters = Array(repeating: [], count: count)
    }

    var isComplete: Bool { receivedCount == blocks.count }

    func request(_ block: Int) -> BlockRequest {
        let begin = block * blockSize
        return BlockRequest(piece: index, begin: begin, length: min(blockSize, size - begin))
    }

    var hasUnrequested: Bool { blocks.contains(.missing) }
}

/// A known address for a torrent and how connecting to it has gone.
struct AddressInfo {
    var source: PeerSource
    var failures = 0
    var nextAttempt = Date.distantPast
    var connected = false
    var banned = false
    var isSeed = false
    var discovered = Date()
}
