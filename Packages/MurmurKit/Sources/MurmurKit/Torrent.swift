import Foundation

/// Downloads and seeds one torrent. Everything here runs on the session's engine queue,
/// except storage access (disk queue) and hashing (a concurrent queue).
final class Torrent {
    unowned let session: Session
    let infoHash: InfoHash
    private(set) var info: TorrentInfo?
    var trackerTiers: [[String]]
    var webSeeds: [String] = []
    var comment: String?
    var createdBy: String?
    var creationDate: Date?
    var displayName: String?
    var savePath: URL
    var addedDate = Date()
    var completedDate: Date?
    var queuePosition = 0
    var ratioLimit: Double?
    var isSequential = false

    // State flags; `state` is derived from them.
    var userPaused = false
    var queued = false
    var finishedByRatio = false
    private(set) var errorMessage: String?
    private(set) var isChecking = false
    private(set) var checkingProgress = 0.0
    private var checkGeneration = 0
    private var checkCancel = CancelToken()

    // Piece state.
    private(set) var have = Bitfield(count: 0)
    var filePriorities: [FilePriority] = []
    private var piecePriority: [UInt8] = []
    private var availability: [UInt16] = []
    private var active: [Int: PieceDownload] = [:]
    private var verifying = Set<Int>()
    private var wantedBytes: Int64 = 0
    private var wantedDoneBytes: Int64 = 0
    private var storage: Storage?

    // Swarm.
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var addresses: [PeerAddress: AddressInfo] = [:]
    private var trackers: [TrackerEntry] = []
    private let trackerKey = UInt32.random(in: 1...UInt32.max)
    private var lastChoke = Date.distantPast
    private var lastOptimistic = Date.distantPast
    private var optimistic: ObjectIdentifier?
    private var lastDHTLookup = Date.distantPast
    private var dhtLookupRunning = false
    private var lastInterestScan = Date.distantPast
    /// Bumped whenever a piece might have become pickable, so peers that found nothing can look again.
    private var pickerGeneration = 0
    private var endgameCache: (generation: Int, done: Int, value: Bool)?

    // Metadata exchange (magnet links).
    private var metadataSize: Int?
    private var metadataPieces: [Data?] = []

    // Stats.
    private var downloadMeter = RateMeter()
    private var uploadMeter = RateMeter()
    var downloadedTotal: Int64 = 0
    var uploadedTotal: Int64 = 0
    var resumeDirty = false
    private var completedTrackerEventPending = false
    private var announcedFinished = false

    init(session: Session, infoHash: InfoHash, info: TorrentInfo?, trackers: [[String]], savePath: URL) {
        self.session = session
        self.infoHash = infoHash
        self.trackerTiers = trackers
        self.savePath = savePath
        if let info { setInfo(info, priorities: nil) }
        rebuildTrackers()
    }

    // MARK: - Derived state

    var name: String { info?.name ?? displayName ?? infoHash.hex }
    var isPrivate: Bool { info?.isPrivate ?? false }

    var state: TorrentState {
        if errorMessage != nil { return .error }
        if isChecking { return .checking }
        if userPaused { return .paused }
        if finishedByRatio { return .finished }
        if queued { return .queued }
        if info == nil { return .fetchingMetadata }
        return isWantedComplete ? .seeding : .downloading
    }

    /// Connected to the swarm and transferring.
    var isRunning: Bool { errorMessage == nil && !isChecking && !userPaused && !queued && !finishedByRatio }
    var isWantedComplete: Bool { info != nil && wantedDoneBytes >= wantedBytes }
    var needsDownloadSlot: Bool { !isWantedComplete }
    var connectedCount: Int { peers.values.filter(\.handshaken).count }
    var peerCount: Int { peers.count }

    var ratio: Double {
        let base = max(downloadedTotal, info.map { min($0.totalLength, wantedDoneBytes) } ?? 0)
        return base > 0 ? Double(uploadedTotal) / Double(base) : 0
    }

    // MARK: - Metadata

    private func setInfo(_ info: TorrentInfo, priorities: [FilePriority]?) {
        self.info = info
        have = Bitfield(count: info.pieceCount)
        availability = Array(repeating: 0, count: info.pieceCount)
        if let priorities, priorities.count == info.files.count {
            filePriorities = priorities
        } else if filePriorities.count != info.files.count {
            filePriorities = Array(repeating: .normal, count: info.files.count)
        }
        storage = Storage(info: info, root: savePath)
        recomputePiecePriorities()
    }

    func restore(have data: Data?, priorities: [FilePriority]?) {
        guard let info else { return }
        if let priorities, priorities.count == info.files.count { filePriorities = priorities }
        if let data, let bits = Bitfield(data: data, count: info.pieceCount) { have = bits }
        recomputePiecePriorities()
    }

    func restoreMetadataName(_ name: String?) { displayName = name }

    /// Piece priorities follow the highest priority of the files they touch. Padding files don't count.
    private func recomputePiecePriorities() {
        guard let info else { return }
        var priorities = [UInt8](repeating: 0, count: info.pieceCount)
        let pieceLength = Int64(info.pieceLength)
        for (i, file) in info.files.enumerated() where !file.isPadding && file.length > 0 {
            let p = UInt8(filePriorities[i].rawValue)
            guard p > 0 else { continue }
            let first = Int(file.offset / pieceLength)
            let last = Int((file.offset + file.length - 1) / pieceLength)
            for piece in first...last where priorities[piece] < p { priorities[piece] = p }
        }
        piecePriority = priorities
        pickerGeneration += 1
        wantedBytes = 0
        wantedDoneBytes = 0
        for piece in 0..<info.pieceCount where priorities[piece] > 0 {
            let size = Int64(info.pieceSize(piece))
            wantedBytes += size
            if have[piece] { wantedDoneBytes += size }
        }
        // Drop in-progress pieces nobody wants any more.
        for (index, _) in active where priorities[index] == 0 { cancelPiece(index) }
    }

    func setFilePriorities(_ changes: [Int: FilePriority]) {
        guard info != nil else { return }
        let wasComplete = isWantedComplete
        for (index, priority) in changes where filePriorities.indices.contains(index) { filePriorities[index] = priority }
        recomputePiecePriorities()
        resumeDirty = true
        for peer in peers.values { updateInterest(peer) }
        if wasComplete && !isWantedComplete {
            finishedByRatio = false
            announcedFinished = false
            session.scheduleQueue()
        }
        checkCompletion()
    }

    private func gotMetadata(_ raw: Data) {
        guard info == nil, let parsed = try? TorrentInfo(rawInfo: raw), parsed.infoHash == infoHash else {
            metadataSize = nil
            metadataPieces = []
            return
        }
        metadataPieces = []
        setInfo(parsed, priorities: nil)
        session.saveTorrentFile(self)
        resumeDirty = true
        session.emit(.metadataReceived(infoHash, name: parsed.name))
        for peer in peers.values {
            peer.metadataRequests.removeAll()
            applyPendingBitfield(peer)
        }
        // Files may already be on disk (a re-added torrent): check them before downloading.
        let sizes = storage?.fileSizes() ?? []
        if sizes.contains(where: { ($0 ?? 0) > 0 }) {
            startCheck()
        } else {
            for peer in peers.values { updateInterest(peer) }
        }
        session.scheduleQueue()
    }

    func metainfo() -> Metainfo? {
        guard let info else { return nil }
        return Metainfo(info: info, trackers: trackerTiers, webSeeds: webSeeds, comment: comment, createdBy: createdBy, creationDate: creationDate)
    }

    // MARK: - Lifecycle

    private var wasRunning = false

    /// Joins or leaves the swarm when the derived running state changes.
    func syncRunning() {
        let running = isRunning
        if running && !wasRunning {
            wasRunning = true
            didStartRunning()
        } else if !running && wasRunning {
            wasRunning = false
            didStopRunning()
        }
    }

    func markLoaded() {
        if isWantedComplete { announcedFinished = true }
    }

    func dropAllPeers() {
        for peer in Array(peers.values) { disconnect(peer, reason: "interface down") }
    }

    func shutdownForQuit() {
        if wasRunning {
            wasRunning = false
            didStopRunning()
        }
        shutdown()
    }

    /// Opens up to the swarm: announces and lets the tick connect to peers.
    func didStartRunning() {
        for tracker in trackers where tracker.client != nil {
            tracker.nextAnnounce = Date()
            tracker.lastAnnounce = nil
        }
        lastDHTLookup = .distantPast
        lastChoke = .distantPast
    }

    /// Leaves the swarm: closes peers and tells trackers we've stopped.
    func didStopRunning() {
        for peer in Array(peers.values) { disconnect(peer, reason: "stopped") }
        for (index, _) in active { cancelPiece(index) }
        for tracker in trackers where tracker.lastAnnounce != nil {
            tracker.client?.announce(announceRequest(event: .stopped), trackerID: tracker.trackerID) { _ in }
            tracker.lastAnnounce = nil
            tracker.status = .idle
        }
        session.diskQueue.async { [storage] in storage?.sync(); storage?.closeAll() }
    }

    func setError(_ message: String?) {
        let hadError = errorMessage != nil
        errorMessage = message
        if let message, !hadError { session.emit(.failed(infoHash, name: name, message: message)) }
        syncRunning()
        resumeDirty = true
        session.scheduleQueue()
    }

    /// Stops for good. Tracker clients are left alone so the "stopped" announce still goes out.
    func shutdown() {
        checkGeneration += 1
        checkCancel.cancel()
        for peer in Array(peers.values) { disconnect(peer, reason: "removed") }
    }

    // MARK: - Checking existing data

    func startCheck(trustResume: Bool = false) {
        guard let info, let storage else { return }
        isChecking = true
        checkingProgress = 0
        syncRunning()
        checkGeneration += 1
        checkCancel.cancel()
        let token = CancelToken()
        checkCancel = token
        let generation = checkGeneration
        let queue = session.queue
        session.diskQueue.async { [weak self] in
            let sizes = storage.fileSizes()
            var result = Bitfield(count: info.pieceCount)
            for piece in 0..<info.pieceCount {
                if piece % 64 == 0 {
                    if token.isCancelled { return }
                    let progress = Double(piece) / Double(info.pieceCount)
                    queue.async { self?.checkingProgress = progress }
                }
                guard storage.mightHave(piece: piece, sizes: sizes) else { continue }
                if let data = try? storage.read(piece: piece, begin: 0, length: info.pieceSize(piece)), data.sha1() == info.pieceHash(piece) {
                    result[piece] = true
                }
            }
            storage.closeAll()
            queue.async {
                guard let self, self.checkGeneration == generation else { return }
                self.finishCheck(result)
            }
        }
    }

    private func finishCheck(_ result: Bitfield) {
        have = result
        isChecking = false
        checkingProgress = 1
        recomputePiecePriorities()
        resumeDirty = true
        if isWantedComplete {
            announcedFinished = true // don't notify for data that was already here
            if completedDate == nil { completedDate = Date() }
        } else {
            finishedByRatio = false
        }
        session.scheduleQueue()
        syncRunning()
    }

    /// Quick resume: keep the saved bitfield only if the files look untouched since.
    func validateResume(fileDates: [Double]?, haveData: Data?) -> Bool {
        guard let info, let storage, haveData != nil else { return false }
        guard let fileDates, fileDates.count == info.files.count else { return have.isEmpty }
        let sizes = storage.fileSizes()
        let dates = storage.fileModificationDates()
        for i in info.files.indices where !info.files[i].isPadding {
            if fileDates[i] == 0 { continue } // never written
            guard sizes[i] != nil, abs(dates[i] - fileDates[i]) < 2 else { return false }
        }
        return true
    }

    func fileDates() -> [Double]? {
        guard let storage else { return nil }
        return storage.fileModificationDates()
    }

    // MARK: - Tick

    func tick(now: Date) {
        downloadMeter.tick()
        uploadMeter.tick()
        for peer in peers.values {
            peer.download.tick()
            peer.upload.tick()
        }
        guard isRunning else { return }

        expireRequests(now: now)
        if now.timeIntervalSince(lastChoke) >= 10 { runChoker(now: now) }
        if now.timeIntervalSince(lastInterestScan) >= 15 {
            lastInterestScan = now
            for peer in peers.values { updateInterest(peer) }
        }
        connectPeers(now: now)
        announceIfNeeded(now: now)
        lookupDHTIfNeeded(now: now)
        maintainPeers(now: now)
        if info == nil { requestMetadataFromAll() }
        for peer in peers.values where peer.handshaken {
            fillRequests(peer)
            serve(peer)
        }
        checkRatio()
    }

    private func expireRequests(now: Date) {
        for peer in peers.values where !peer.requests.isEmpty {
            // In endgame be quick to re-ask; otherwise give slow peers a minute.
            let limit: TimeInterval = peer.download.rate > 0 ? 30 : 45
            let stale = peer.requests.filter { now.timeIntervalSince($0.value) > limit }
            guard !stale.isEmpty else { continue }
            peer.snubbed = true
            for (request, _) in stale {
                peer.requests[request] = nil
                releaseRequest(request, from: peer)
                peer.connection.send(.cancel(request))
            }
        }
    }

    private func maintainPeers(now: Date) {
        let maxPeers = session.config.maxPeersPerTorrent
        for peer in Array(peers.values) {
            let silent = now.timeIntervalSince(peer.connection.lastReceived)
            if !peer.handshaken && now.timeIntervalSince(peer.connectedAt) > 20 {
                disconnect(peer, reason: "handshake timeout"); continue
            }
            if silent > 180 { disconnect(peer, reason: "inactive"); continue }
            if isWantedComplete && peer.isSeed && info != nil { disconnect(peer, reason: "both seeding"); continue }
            // Free slots held by peers neither side wants anything from.
            if peers.count > maxPeers * 3 / 4, !peer.amInterested, !peer.peerInterested, now.timeIntervalSince(peer.connectedAt) > 90 {
                disconnect(peer, reason: "uninteresting"); continue
            }
            if now.timeIntervalSince(peer.connection.lastSent) > 100 { peer.connection.send(.keepAlive) }
            if now.timeIntervalSince(peer.lastPex) > 60 { sendPex(peer) }
        }
    }

    private func checkRatio() {
        guard isWantedComplete else { return }
        let limit = ratioLimit ?? session.config.seedRatioLimit
        if (limit.map { $0 >= 0 && ratio >= $0 } ?? false) || !session.config.seedWhenComplete {
            finishedByRatio = true
            syncRunning()
            resumeDirty = true
            session.scheduleQueue()
        }
    }

    // MARK: - Peers and connections

    func addPeers(_ list: [PeerAddress], source: PeerSource) {
        for address in list where address.isUsable {
            if addresses[address] == nil {
                guard addresses.count < 3000 else { break }
                addresses[address] = AddressInfo(source: source)
            }
        }
    }

    var knownPeerCount: Int { addresses.count }

    private func connectPeers(now: Date) {
        let maxPeers = session.config.maxPeersPerTorrent
        guard peers.count < maxPeers else { return }
        var budget = min(session.connectionBudget(), maxPeers - peers.count, 12)
        guard budget > 0 else { return }
        let seeding = isWantedComplete
        let candidates = addresses.filter { _, info in
            !info.connected && !info.banned && info.nextAttempt <= now && !(seeding && info.isSeed)
        }
        .sorted { a, b in
            if a.value.failures != b.value.failures { return a.value.failures < b.value.failures }
            return a.value.discovered > b.value.discovered
        }
        for (address, _) in candidates {
            guard budget > 0 else { break }
            budget -= 1
            connect(to: address)
        }
    }

    private func connect(to address: PeerAddress) {
        guard var entry = addresses[address] else { return }
        entry.connected = true
        addresses[address] = entry
        let connection = PeerConnection(address: address, queue: session.queue, requiredInterface: session.requiredInterface)
        let peer = Peer(connection: connection, address: address, source: entry.source)
        let id = ObjectIdentifier(peer)
        peers[id] = peer
        session.halfOpen += 1
        var countedHalfOpen = true
        connection.downloadLimiter = session.downloadLimiter
        connection.onConnected = { [weak self, weak peer] in
            guard let self, let peer else { return }
            if countedHalfOpen { session.halfOpen -= 1; countedHalfOpen = false }
            peer.connection.sendHandshake(Handshake(reserved: Handshake.ours(dht: session.dht != nil && !isPrivate), infoHash: infoHash, peerID: session.peerID))
        }
        connection.onHandshake = { [weak self, weak peer] handshake in
            guard let self, let peer else { return false }
            return didHandshake(peer, handshake)
        }
        wire(peer)
        connection.onClose = { [weak self, weak peer] error in
            guard let self, let peer else { return }
            if countedHalfOpen { session.halfOpen -= 1; countedHalfOpen = false }
            peerClosed(peer, error: error)
        }
        connection.start()
    }

    /// An incoming connection whose handshake named this torrent.
    func accept(_ connection: PeerConnection, handshake: Handshake) -> Bool {
        guard isRunning, peers.count < session.config.maxPeersPerTorrent + 10 else { return false }
        guard let address = PeerAddress(endpoint: connection.remoteEndpoint) else { return false }
        if addresses[address]?.banned == true { return false }
        if peers.values.contains(where: { $0.address == address }) { return false }
        let peer = Peer(connection: connection, address: address, source: .incoming)
        peers[ObjectIdentifier(peer)] = peer
        connection.downloadLimiter = session.downloadLimiter
        wire(peer)
        connection.onClose = { [weak self, weak peer] error in
            guard let self, let peer else { return }
            peerClosed(peer, error: error)
        }
        connection.sendHandshake(Handshake(reserved: Handshake.ours(dht: session.dht != nil && !isPrivate), infoHash: infoHash, peerID: session.peerID))
        session.incomingConnections += 1
        return didHandshake(peer, handshake)
    }

    private func wire(_ peer: Peer) {
        peer.connection.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            handle(message, from: peer)
        }
        peer.connection.onDrain = { [weak self, weak peer] in
            guard let self, let peer, !peer.incoming.isEmpty else { return }
            serve(peer)
        }
    }

    private func didHandshake(_ peer: Peer, _ handshake: Handshake) -> Bool {
        guard handshake.infoHash == infoHash, handshake.peerID != session.peerID else {
            if handshake.peerID == session.peerID { addresses[peer.address]?.banned = true }
            return false
        }
        // Don't keep two connections to the same client.
        if peers.values.contains(where: { $0 !== peer && $0.handshaken && $0.peerID == handshake.peerID }) { return false }
        peer.handshaken = true
        peer.peerID = handshake.peerID
        peer.client = PeerIdentity.clientName(for: handshake.peerID)
        peer.supportsExtensions = handshake.supportsExtensions
        peer.supportsDHT = handshake.supportsDHT
        addresses[peer.address, default: AddressInfo(source: peer.source)].failures = 0
        addresses[peer.address]?.connected = true

        if info != nil, !have.isEmpty { peer.connection.send(.bitfield(have.data)) }
        if peer.supportsExtensions { sendExtendedHandshake(peer) }
        if peer.supportsDHT, session.dht != nil, !isPrivate { peer.connection.send(.port(session.listenPort)) }
        // Unchoke straight away when a slot is free.
        return true
    }

    private func peerClosed(_ peer: Peer, error: Error?) {
        let id = ObjectIdentifier(peer)
        guard peers[id] != nil else { return }
        if var entry = addresses[peer.address] {
            entry.connected = false
            if !peer.handshaken {
                entry.failures += 1
                entry.nextAttempt = Date().addingTimeInterval(min(30 * pow(2, Double(entry.failures)), 3600))
                if entry.failures >= 5 && entry.source != .magnet && entry.source != .manual { addresses[peer.address] = nil } else { addresses[peer.address] = entry }
            } else {
                entry.nextAttempt = Date().addingTimeInterval(peer.isSeed && isWantedComplete ? 3600 : 90)
                entry.isSeed = peer.isSeed
                addresses[peer.address] = entry
            }
        }
        removePeer(peer)
    }

    private func disconnect(_ peer: Peer, reason: String) {
        peer.connection.close()
        if var entry = addresses[peer.address] {
            entry.connected = false
            entry.isSeed = peer.isSeed
            entry.nextAttempt = Date().addingTimeInterval(reason == "both seeding" ? 3600 : 120)
            addresses[peer.address] = entry
        }
        removePeer(peer)
    }

    private func removePeer(_ peer: Peer) {
        let id = ObjectIdentifier(peer)
        guard peers.removeValue(forKey: id) != nil else { return }
        for request in peer.requests.keys { releaseRequest(request, from: peer) }
        peer.requests.removeAll()
        if info != nil {
            if peer.hasAll {
                for i in availability.indices where availability[i] > 0 { availability[i] -= 1 }
            } else if let bits = peer.bitfield {
                for i in 0..<bits.count where bits[i] && availability[i] > 0 { availability[i] -= 1 }
            }
        }
        if optimistic == id { optimistic = nil }
        // Pick someone else up quickly if a download slot opened.
        if !peer.amChoking { lastChoke = .distantPast }
    }

    // MARK: - Messages

    private func handle(_ message: PeerMessage, from peer: Peer) {
        switch message {
        case .keepAlive:
            break
        case .choke:
            peer.peerChoking = true
            // Without the fast extension a choke discards every outstanding request.
            for request in peer.requests.keys { releaseRequest(request, from: peer) }
            peer.requests.removeAll()
        case .unchoke:
            peer.peerChoking = false
            fillRequests(peer)
        case .interested:
            peer.peerInterested = true
            if peer.amChoking && unchokedCount < uploadSlots { unchoke(peer) }
        case .notInterested:
            peer.peerInterested = false
        case .have(let index):
            receivedHave(index, from: peer)
        case .bitfield(let data):
            receivedBitfield(data, from: peer)
        case .request(let request):
            receivedRequest(request, from: peer)
        case .piece(let index, let begin, let block):
            receivedBlock(index: index, begin: begin, data: block, from: peer)
        case .cancel(let request):
            peer.incoming.removeAll { $0 == request }
        case .port(let port):
            if let dht = session.dht, let ip = IPv4Literal(peer.address.host) { dht.ping(NodeEndpoint(ip: ip, port: port)) }
        case .extended(let id, let payload):
            receivedExtended(id: id, payload: payload, from: peer)
        case .unknown:
            break
        }
    }

    private func receivedHave(_ index: Int, from peer: Peer) {
        guard let info else {
            if peer.pendingHaves.count < 100_000 { peer.pendingHaves.append(index) }
            return
        }
        guard index >= 0, index < info.pieceCount else { disconnect(peer, reason: "bad have"); return }
        if peer.bitfield == nil { peer.bitfield = Bitfield(count: info.pieceCount) }
        guard peer.bitfield?[index] == false else { return }
        peer.bitfield?[index] = true
        availability[index] &+= 1
        pickerGeneration += 1
        if !peer.amInterested && !have[index] && piecePriority[index] > 0 { setInterested(peer, true) }
        if peer.amInterested && !peer.peerChoking { fillRequests(peer) }
    }

    private func receivedBitfield(_ data: Data, from peer: Peer) {
        guard let info else { peer.pendingBitfield = data; return }
        guard let bits = Bitfield(data: data, count: info.pieceCount) else { disconnect(peer, reason: "bad bitfield"); return }
        if let old = peer.bitfield {
            for i in 0..<old.count where old[i] && availability[i] > 0 { availability[i] -= 1 }
        }
        peer.bitfield = bits
        for i in 0..<bits.count where bits[i] { availability[i] &+= 1 }
        pickerGeneration += 1
        updateInterest(peer)
    }

    private func applyPendingBitfield(_ peer: Peer) {
        if let data = peer.pendingBitfield {
            peer.pendingBitfield = nil
            receivedBitfield(data, from: peer)
        }
        let haves = peer.pendingHaves
        peer.pendingHaves = []
        for index in haves { receivedHave(index, from: peer) }
        if peer.bitfield == nil, let info { peer.bitfield = Bitfield(count: info.pieceCount) }
    }

    private func updateInterest(_ peer: Peer) {
        guard let info, peer.handshaken else { return }
        var wants = false
        if let bits = peer.bitfield, !bits.isEmpty || peer.hasAll {
            for i in 0..<info.pieceCount where piecePriority[i] > 0 && !have[i] && (peer.hasAll || bits[i]) {
                wants = true
                break
            }
        }
        if wants != peer.amInterested { setInterested(peer, wants) }
    }

    private func setInterested(_ peer: Peer, _ interested: Bool) {
        peer.amInterested = interested
        peer.connection.send(interested ? .interested : .notInterested)
    }

    // MARK: - Downloading

    private var maxActivePieces: Int {
        guard let info else { return 0 }
        let byMemory = max(8, (256 << 20) / max(info.pieceLength, 1))
        return min(byMemory, 16 + peers.count * 2)
    }

    private func fillRequests(_ peer: Peer) {
        guard info != nil, isRunning, peer.handshaken, !peer.peerChoking, peer.amInterested else { return }
        let target = peer.snubbed ? 2 : peer.pipelineTarget
        while peer.requests.count < target {
            guard let (request, piece, block) = nextRequest(for: peer) else { break }
            piece.blocks[block] = .requested
            piece.requesters[block].append(ObjectIdentifier(peer))
            peer.requests[request] = Date()
            peer.connection.send(.request(request))
        }
    }

    private func nextRequest(for peer: Peer) -> (BlockRequest, PieceDownload, Int)? {
        let id = ObjectIdentifier(peer)
        // Finish pieces already started, highest priority and furthest along first.
        let started = active.values.filter { peer.has($0.index) }.sorted {
            let pa = piecePriority[$0.index], pb = piecePriority[$1.index]
            if pa != pb { return pa > pb }
            if isSequential { return $0.index < $1.index }
            return $0.receivedCount > $1.receivedCount
        }
        for piece in started {
            if let block = piece.blocks.firstIndex(of: .missing) { return (piece.request(block), piece, block) }
        }
        if active.count < maxActivePieces && peer.pickMissGeneration != pickerGeneration {
            if let index = pickPiece(for: peer) {
                let piece = PieceDownload(index: index, size: info!.pieceSize(index))
                active[index] = piece
                return (piece.request(0), piece, 0)
            }
            peer.pickMissGeneration = pickerGeneration
        }
        // Endgame: everything left is requested, so ask more peers for the same blocks.
        if isEndgame {
            for piece in started {
                for (block, state) in piece.blocks.enumerated() where state == .requested {
                    let askers = piece.requesters[block]
                    if askers.count < 3 && !askers.contains(id) { return (piece.request(block), piece, block) }
                }
            }
        }
        return nil
    }

    /// Rarest first among the highest priority, with random tie breaks; lowest index in sequential mode.
    private func pickPiece(for peer: Peer) -> Int? {
        guard let info else { return nil }
        var best: Int?
        var bestPriority: UInt8 = 0
        var bestAvailability = UInt16.max
        var ties = 0
        let count = info.pieceCount
        // Start the scan at a random offset so peers don't all chase the same piece.
        let offset = isSequential ? 0 : Int.random(in: 0..<count)
        for n in 0..<count {
            let i = (n + offset) % count
            let p = piecePriority[i]
            guard p > 0, p >= bestPriority, !have[i], active[i] == nil, !verifying.contains(i), peer.has(i) else { continue }
            if isSequential {
                // Ascending scan: keep the first piece of the highest priority seen.
                if p > bestPriority { best = i; bestPriority = p }
                if bestPriority == UInt8(FilePriority.high.rawValue) { break }
                continue
            }
            let a = availability[i]
            if p > bestPriority || a < bestAvailability {
                best = i; bestPriority = p; bestAvailability = a; ties = 1
            } else if a == bestAvailability {
                ties += 1
                if Int.random(in: 0..<ties) == 0 { best = i }
            }
        }
        return best
    }

    private var isEndgame: Bool {
        guard let info else { return false }
        if let cache = endgameCache, cache.generation == pickerGeneration, cache.done == have.cardinality + active.count { return cache.value }
        let value = computeEndgame(info)
        endgameCache = (pickerGeneration, have.cardinality + active.count, value)
        return value
    }

    private func computeEndgame(_ info: TorrentInfo) -> Bool {
        let missing = wantedBytes - wantedDoneBytes
        // Endgame once every missing piece is in flight and none has unrequested blocks.
        guard missing <= Int64(info.pieceLength) * Int64(max(active.count + verifying.count, 1)) else { return false }
        if active.values.contains(where: \.hasUnrequested) { return false }
        for i in 0..<info.pieceCount where piecePriority[i] > 0 && !have[i] && active[i] == nil && !verifying.contains(i) { return false }
        return true
    }

    private func releaseRequest(_ request: BlockRequest, from peer: Peer) {
        guard let piece = active[request.piece] else { return }
        let block = request.begin / blockSize
        guard piece.blocks.indices.contains(block) else { return }
        piece.requesters[block].removeAll { $0 == ObjectIdentifier(peer) }
        if piece.blocks[block] == .requested && piece.requesters[block].isEmpty { piece.blocks[block] = .missing }
    }

    private func cancelPiece(_ index: Int) {
        guard let piece = active.removeValue(forKey: index) else { return }
        pickerGeneration += 1
        for askers in piece.requesters {
            for id in askers {
                guard let peer = peers[id] else { continue }
                for request in peer.requests.keys where request.piece == index {
                    peer.requests[request] = nil
                    peer.connection.send(.cancel(request))
                }
            }
        }
    }

    private func receivedBlock(index: Int, begin: Int, data: Data, from peer: Peer) {
        let request = BlockRequest(piece: index, begin: begin, length: data.count)
        let wasRequested = peer.requests.removeValue(forKey: request) != nil
        peer.download.add(data.count)
        downloadMeter.add(data.count)
        downloadedTotal += Int64(data.count)
        session.recordDownload(data.count)
        peer.lastBlockReceived = Date()
        peer.snubbed = false
        resumeDirty = true

        guard let piece = active[index], begin % blockSize == 0 else {
            if wasRequested { fillRequests(peer) }
            return
        }
        let block = begin / blockSize
        guard piece.blocks.indices.contains(block), piece.request(block).length == data.count else { return }
        if piece.blocks[block] != .received {
            piece.data.replaceSubrange(begin ..< begin + data.count, with: data)
            piece.blocks[block] = .received
            piece.receivedCount += 1
            piece.contributors.insert(peer.address.host)
        }
        // Endgame duplicates: cancel the same block everywhere else.
        for other in piece.requesters[block] where other != ObjectIdentifier(peer) {
            if let p = peers[other], p.requests.removeValue(forKey: request) != nil { p.connection.send(.cancel(request)) }
        }
        piece.requesters[block] = []
        if piece.isComplete {
            active[index] = nil
            verify(piece)
        }
        fillRequests(peer)
    }

    private func verify(_ piece: PieceDownload) {
        guard let info, let storage else { return }
        verifying.insert(piece.index)
        let expected = info.pieceHash(piece.index)
        let data = piece.data
        let queue = session.queue
        let diskQueue = session.diskQueue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = data.sha1() == expected
            guard ok else {
                queue.async { self?.pieceFailed(piece) }
                return
            }
            diskQueue.async {
                do {
                    try storage.write(piece: piece.index, data: data)
                    queue.async { self?.pieceCompleted(piece.index) }
                } catch {
                    queue.async {
                        self?.verifying.remove(piece.index)
                        self?.setError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func pieceFailed(_ piece: PieceDownload) {
        verifying.remove(piece.index)
        pickerGeneration += 1
        // Ban a peer that alone sent a bad piece, or keeps sending them.
        for peer in peers.values where piece.contributors.contains(peer.address.host) {
            peer.hashFailures += 1
            if piece.contributors.count == 1 || peer.hashFailures >= 3 {
                addresses[peer.address]?.banned = true
                disconnect(peer, reason: "sent bad data")
            }
        }
    }

    private func pieceCompleted(_ index: Int) {
        verifying.remove(index)
        guard let info, !have[index] else { return }
        have[index] = true
        if piecePriority[index] > 0 { wantedDoneBytes += Int64(info.pieceSize(index)) }
        resumeDirty = true
        for peer in peers.values where peer.handshaken {
            peer.connection.send(.have(index))
        }
        checkCompletion()
    }

    private func checkCompletion() {
        guard isWantedComplete, !announcedFinished else { return }
        announcedFinished = true
        completedDate = Date()
        resumeDirty = true
        if have.isFull {
            completedTrackerEventPending = true
            for tracker in trackers where tracker.lastAnnounce != nil { tracker.nextAnnounce = Date() }
        }
        session.diskQueue.async { [storage] in storage?.sync() }
        for peer in peers.values { updateInterest(peer) }
        session.emit(.finished(infoHash, name: name))
        session.scheduleQueue()
        session.saveResume(self)
    }

    // MARK: - Uploading

    private var uploadSlots: Int {
        let limit = session.uploadLimiter.bytesPerSecond
        if limit > 0 { return max(2, min(session.config.uploadSlotsPerTorrent, limit / (24 * 1024))) }
        return session.config.uploadSlotsPerTorrent
    }

    private var unchokedCount: Int { peers.values.filter { !$0.amChoking }.count }

    private func unchoke(_ peer: Peer) {
        peer.amChoking = false
        peer.lastUnchoked = Date()
        peer.connection.send(.unchoke)
    }

    private func choke(_ peer: Peer) {
        peer.amChoking = true
        peer.incoming.removeAll()
        peer.connection.send(.choke)
    }

    /// Tit-for-tat: unchoke the peers that give us the most (or take the most when seeding), plus one at random.
    private func runChoker(now: Date) {
        lastChoke = now
        let interested = peers.values.filter { $0.handshaken && $0.peerInterested }
        let seeding = isWantedComplete
        let ranked = interested.sorted {
            let a = seeding ? $0.upload.rate : $0.download.rate
            let b = seeding ? $1.upload.rate : $1.download.rate
            if a != b { return a > b }
            return $0.lastUnchoked < $1.lastUnchoked
        }
        let regular = max(uploadSlots - 1, 1)
        var chosen = Set(ranked.prefix(regular).map(ObjectIdentifier.init))
        if now.timeIntervalSince(lastOptimistic) >= 30 || optimistic.map({ peers[$0] == nil }) ?? true {
            lastOptimistic = now
            let rest = ranked.dropFirst(regular)
            // Newcomers are three times as likely to be picked, to get them started.
            let weighted = rest.flatMap { now.timeIntervalSince($0.connectedAt) < 60 ? [$0, $0, $0] : [$0] }
            optimistic = weighted.randomElement().map(ObjectIdentifier.init)
        }
        if let optimistic { chosen.insert(optimistic) }
        for peer in peers.values where peer.handshaken {
            let should = chosen.contains(ObjectIdentifier(peer))
            if should && peer.amChoking { unchoke(peer) } else if !should && !peer.amChoking { choke(peer) }
        }
    }

    private func receivedRequest(_ request: BlockRequest, from peer: Peer) {
        guard let info, !peer.amChoking, request.piece >= 0, request.piece < info.pieceCount, have[request.piece],
              request.length > 0, request.length <= 128 * 1024, request.begin >= 0,
              request.begin + request.length <= info.pieceSize(request.piece) else { return }
        guard peer.incoming.count < 512, !peer.incoming.contains(request) else { return }
        peer.incoming.append(request)
        serve(peer)
    }

    private func serve(_ peer: Peer) {
        guard let storage, !peer.isServing, !peer.amChoking, !peer.incoming.isEmpty, peer.connection.queuedSendBytes < 512 * 1024 else { return }
        let delay = session.uploadLimiter.delay
        if delay > 0 {
            peer.isServing = true
            session.queue.asyncAfter(deadline: .now() + delay) { [weak self, weak peer] in
                guard let self, let peer else { return }
                peer.isServing = false
                serve(peer)
            }
            return
        }
        let request = peer.incoming.removeFirst()
        peer.isServing = true
        session.diskQueue.async { [weak self, weak peer] in
            let data = try? storage.read(piece: request.piece, begin: request.begin, length: request.length)
            self?.session.queue.async { [weak self] in
                guard let self, let peer else { return }
                peer.isServing = false
                guard peers[ObjectIdentifier(peer)] != nil else { return }
                guard let data else {
                    // The data went missing from disk: recheck rather than send garbage.
                    if !isChecking { setError("Downloaded files were moved or deleted. Use Verify Local Data to recheck.") }
                    return
                }
                if !peer.amChoking {
                    peer.connection.send(.piece(index: request.piece, begin: request.begin, block: data))
                    peer.upload.add(data.count)
                    uploadMeter.add(data.count)
                    uploadedTotal += Int64(data.count)
                    session.recordUpload(data.count)
                    _ = session.uploadLimiter.consume(data.count)
                    resumeDirty = true
                }
                serve(peer)
            }
        }
    }

    // MARK: - Extension protocol (BEP 10): metadata and PEX

    private static let ourExtensions: [String: UInt8] = ["ut_metadata": 1, "ut_pex": 2]

    private func sendExtendedHandshake(_ peer: Peer) {
        var m: [String: BencodeValue] = ["ut_metadata": .integer(1)]
        if !isPrivate && session.config.enablePEX { m["ut_pex"] = .integer(2) }
        var dict: [String: BencodeValue] = [
            "m": .dictionary(m),
            "p": .integer(Int64(session.listenPort)),
            "v": BencodeValue("Murmur \(PeerIdentity.clientVersion)"),
            "reqq": .integer(500),
        ]
        if let info { dict["metadata_size"] = .integer(Int64(info.rawInfo.count)) }
        if let compact = peer.address.compact { dict["yourip"] = .bytes(compact.prefix(compact.count - 2)) }
        peer.connection.send(.extended(id: 0, payload: BencodeValue.dictionary(dict).encoded()))
    }

    private func receivedExtended(id: UInt8, payload: Data, from peer: Peer) {
        if id == 0 {
            guard let dict = try? BencodeDecoder.decode(payload) else { return }
            if let m = dict["m"]?.dictionary {
                for (name, value) in m {
                    if let n = value.int, n >= 0, n <= 255 {
                        if n == 0 { peer.extensions[name] = nil } else { peer.extensions[name] = UInt8(n) }
                    }
                }
            }
            if let port = dict["p"]?.int, port > 0, port < 65536 { peer.listenPort = UInt16(port) }
            if let reqq = dict["reqq"]?.int, reqq > 0 { peer.maxRequests = Int(min(reqq, 2000)) }
            if let v = dict["v"]?.string, !v.isEmpty { peer.client = v }
            if let size = dict["metadata_size"]?.int, size > 0, size < 64 << 20 { peer.metadataSize = Int(size) }
            if info == nil { requestMetadata(from: peer) }
            return
        }
        switch id {
        case Torrent.ourExtensions["ut_metadata"]: receivedMetadataMessage(payload, from: peer)
        case Torrent.ourExtensions["ut_pex"]: receivedPex(payload, from: peer)
        default: break
        }
    }

    private func requestMetadataFromAll() {
        for peer in peers.values where peer.handshaken { requestMetadata(from: peer) }
    }

    private func requestMetadata(from peer: Peer) {
        guard info == nil, let ext = peer.extensions["ut_metadata"], let size = peer.metadataSize else { return }
        if metadataSize == nil {
            metadataSize = size
            metadataPieces = Array(repeating: nil, count: (size + blockSize - 1) / blockSize)
        }
        guard metadataSize == size else { return }
        let now = Date()
        peer.metadataRequests = peer.metadataRequests.filter { now.timeIntervalSince($0.value) < 15 }
        let inFlightElsewhere = Set(peers.values.filter { $0 !== peer }.flatMap { $0.metadataRequests.keys })
        for index in metadataPieces.indices where metadataPieces[index] == nil && peer.metadataRequests[index] == nil {
            guard peer.metadataRequests.count < 4 else { break }
            if inFlightElsewhere.contains(index) && metadataPieces.count > 1 { continue }
            peer.metadataRequests[index] = now
            let message = BencodeValue.dictionary(["msg_type": .integer(0), "piece": .integer(Int64(index))])
            peer.connection.send(.extended(id: ext, payload: message.encoded()))
        }
    }

    private func receivedMetadataMessage(_ payload: Data, from peer: Peer) {
        guard let (dict, used) = try? BencodeDecoder.decodePrefix(payload), let type = dict["msg_type"]?.int, let index = dict["piece"]?.int else { return }
        let piece = Int(index)
        switch type {
        case 0: // request
            guard let ext = peer.extensions["ut_metadata"] else { return }
            if let info, piece >= 0, piece * blockSize < info.rawInfo.count {
                let start = piece * blockSize
                let chunk = info.rawInfo.subdata(in: start ..< min(start + blockSize, info.rawInfo.count))
                var message = BencodeValue.dictionary(["msg_type": .integer(1), "piece": .integer(index), "total_size": .integer(Int64(info.rawInfo.count))]).encoded()
                message.append(chunk)
                peer.connection.send(.extended(id: ext, payload: message))
            } else {
                let message = BencodeValue.dictionary(["msg_type": .integer(2), "piece": .integer(index)])
                peer.connection.send(.extended(id: ext, payload: message.encoded()))
            }
        case 1: // data
            peer.metadataRequests[piece] = nil
            guard info == nil, metadataPieces.indices.contains(piece), metadataPieces[piece] == nil else { return }
            let chunk = payload.subdata(in: payload.startIndex + used ..< payload.endIndex)
            let expected = min(blockSize, metadataSize! - piece * blockSize)
            guard chunk.count == expected else { return }
            metadataPieces[piece] = chunk
            if metadataPieces.allSatisfy({ $0 != nil }) {
                let raw = metadataPieces.reduce(into: Data()) { $0.append($1!) }
                if raw.sha1() == infoHash.bytes {
                    gotMetadata(raw)
                } else {
                    metadataPieces = Array(repeating: nil, count: metadataPieces.count)
                }
            } else {
                requestMetadata(from: peer)
            }
        case 2: // reject
            peer.metadataRequests[piece] = nil
            peer.extensions["ut_metadata"] = nil
        default:
            break
        }
    }

    private func sendPex(_ peer: Peer) {
        peer.lastPex = Date()
        guard !isPrivate, session.config.enablePEX, let ext = peer.extensions["ut_pex"] else { return }
        let current = Set(peers.values.filter { $0 !== peer && $0.handshaken }.compactMap(\.reachableAddress))
        let added = current.subtracting(peer.pexSent).prefix(50)
        let dropped = peer.pexSent.subtracting(current).prefix(50)
        guard !added.isEmpty || !dropped.isEmpty else { return }
        var dict: [String: BencodeValue] = [:]
        let added4 = added.filter { !$0.isIPv6 }, added6 = added.filter(\.isIPv6)
        let dropped4 = dropped.filter { !$0.isIPv6 }, dropped6 = dropped.filter(\.isIPv6)
        dict["added"] = .bytes(added4.compactMap(\.compact).reduce(Data(), +))
        dict["added.f"] = .bytes(Data(repeating: 0, count: added4.count))
        if !added6.isEmpty {
            dict["added6"] = .bytes(added6.compactMap(\.compact).reduce(Data(), +))
            dict["added6.f"] = .bytes(Data(repeating: 0, count: added6.count))
        }
        dict["dropped"] = .bytes(dropped4.compactMap(\.compact).reduce(Data(), +))
        if !dropped6.isEmpty { dict["dropped6"] = .bytes(dropped6.compactMap(\.compact).reduce(Data(), +)) }
        peer.pexSent.formUnion(added)
        peer.pexSent.subtract(dropped)
        peer.connection.send(.extended(id: ext, payload: BencodeValue.dictionary(dict).encoded()))
    }

    private func receivedPex(_ payload: Data, from peer: Peer) {
        guard !isPrivate, session.config.enablePEX, let dict = try? BencodeDecoder.decode(payload) else { return }
        var list: [PeerAddress] = []
        if let added = dict["added"]?.data { list += PeerAddress.parseCompact(added).prefix(100) }
        if let added6 = dict["added6"]?.data { list += PeerAddress.parseCompact(added6, ipv6: true).prefix(100) }
        addPeers(list, source: .pex)
    }

    // MARK: - Trackers and DHT

    func rebuildTrackers() {
        let existing = Dictionary(trackers.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [TrackerEntry] = []
        var seen = Set<String>()
        for (tier, urls) in trackerTiers.enumerated() {
            for url in urls where seen.insert(url).inserted {
                list.append(existing[url] ?? TrackerEntry(url: url, tier: tier, queue: session.queue))
            }
        }
        trackers = list
    }

    func addTrackers(_ urls: [String]) {
        let known = Set(trackerTiers.flatMap { $0 })
        let fresh = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !known.contains($0) }
        guard !fresh.isEmpty else { return }
        for url in fresh { trackerTiers.append([url]) }
        rebuildTrackers()
        resumeDirty = true
        session.saveTorrentFile(self)
    }

    func removeTracker(_ url: String) {
        trackerTiers = trackerTiers.map { $0.filter { $0 != url } }.filter { !$0.isEmpty }
        trackers.first { $0.url == url }?.client?.cancel()
        rebuildTrackers()
        resumeDirty = true
        session.saveTorrentFile(self)
    }

    func reannounce() {
        guard isRunning else { return }
        for tracker in trackers where tracker.client != nil && tracker.status != .announcing { tracker.nextAnnounce = Date() }
        lastDHTLookup = .distantPast
    }

    private func announceRequest(event: AnnounceEvent) -> AnnounceRequest {
        let left: Int64 = info == nil ? 16384 : max(wantedBytes - wantedDoneBytes, 0)
        let needPeers = peers.count < session.config.maxPeersPerTorrent / 2
        return AnnounceRequest(
            infoHash: infoHash, peerID: session.peerID, port: session.listenPort,
            uploaded: uploadedTotal, downloaded: downloadedTotal, left: left,
            event: event, numWant: event == .stopped ? 0 : (needPeers ? 80 : 20), key: trackerKey
        )
    }

    private func announceIfNeeded(now: Date) {
        for tracker in trackers where tracker.client != nil && tracker.status != .announcing && tracker.nextAnnounce <= now {
            let event: AnnounceEvent
            if tracker.lastAnnounce == nil { event = .started } else if completedTrackerEventPending { event = .completed } else { event = .none }
            tracker.status = .announcing
            tracker.client?.announce(announceRequest(event: event), trackerID: tracker.trackerID) { [weak self, weak tracker] result in
                guard let self, let tracker else { return }
                switch result {
                case .success(let response):
                    tracker.status = .working
                    tracker.message = response.warning
                    tracker.failures = 0
                    tracker.lastAnnounce = Date()
                    tracker.seeders = response.seeders
                    tracker.leechers = response.leechers
                    tracker.lastPeerCount = response.peers.count
                    if let id = response.trackerID { tracker.trackerID = id }
                    tracker.interval = min(max(response.interval, 60), 3 * 3600)
                    tracker.minInterval = max(response.minInterval ?? 60, 30)
                    var next = tracker.interval
                    // Ask again sooner while we're short of peers.
                    if isRunning && !isWantedComplete && connectedCount < 10 { next = min(next, max(tracker.minInterval, 300)) }
                    tracker.nextAnnounce = Date().addingTimeInterval(next)
                    if event == .completed { completedTrackerEventPending = false }
                    if isRunning { addPeers(response.peers, source: .tracker) }
                case .failure(let error):
                    tracker.status = .failed
                    tracker.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    tracker.failures += 1
                    tracker.nextAnnounce = Date().addingTimeInterval(min(30 * pow(2, Double(tracker.failures - 1)), 3600))
                    if event == .started { tracker.lastAnnounce = nil }
                }
                if !isRunning { tracker.status = .idle }
            }
        }
    }

    private func lookupDHTIfNeeded(now: Date) {
        guard let dht = session.dht, !isPrivate, !dhtLookupRunning else { return }
        let interval: TimeInterval = (info == nil || connectedCount < 10) ? 120 : 900
        guard now.timeIntervalSince(lastDHTLookup) >= interval else { return }
        lastDHTLookup = now
        dhtLookupRunning = true
        dht.getPeers(infoHash, announcePort: session.listenPort, onPeers: { [weak self] found in
            guard let self, isRunning else { return }
            addPeers(found, source: .dht)
        }, onDone: { [weak self] in
            self?.dhtLookupRunning = false
        })
    }

    // MARK: - Status

    func status() -> TorrentStatus {
        let connected = peers.values.filter(\.handshaken)
        let seeders = trackers.compactMap(\.seeders).max()
        let leechers = trackers.compactMap(\.leechers).max()
        let rate = downloadMeter.rate
        let remaining = max(wantedBytes - wantedDoneBytes, 0)
        let largest = info?.files.filter { !$0.isPadding }.max { $0.length < $1.length }
        let ext = largest.map { ($0.name as NSString).pathExtension.lowercased() }
        return TorrentStatus(
            id: infoHash,
            name: name,
            state: state,
            progress: info == nil ? 0 : (wantedBytes == 0 ? 1 : Double(wantedDoneBytes) / Double(wantedBytes)),
            totalSize: info?.totalLength ?? 0,
            wantedSize: wantedBytes,
            completedSize: wantedDoneBytes,
            downloadRate: rate,
            uploadRate: uploadMeter.rate,
            downloaded: downloadedTotal,
            uploaded: uploadedTotal,
            ratio: ratio,
            eta: state == .downloading && rate > 0 ? TimeInterval(remaining) / TimeInterval(rate) : nil,
            connectedPeers: connected.count,
            connectedSeeds: connected.filter(\.isSeed).count,
            knownPeers: addresses.count,
            swarmSeeders: seeders,
            swarmLeechers: leechers,
            savePath: savePath,
            contentURL: info.map { savePath.appendingPathComponent($0.name) },
            addedDate: addedDate,
            completedDate: completedDate,
            errorMessage: errorMessage,
            checkingProgress: isChecking ? checkingProgress : nil,
            isPrivate: isPrivate,
            hasMetadata: info != nil,
            fileCount: info?.files.filter { !$0.isPadding }.count ?? 0,
            isSequential: isSequential,
            queuePosition: queuePosition,
            magnetLink: MagnetLink(infoHash: infoHash, displayName: name, trackers: trackerTiers.flatMap { $0 }).uri,
            primaryFileExtension: ext,
            isMultiFile: info?.isMultiFile ?? false,
            ratioLimit: ratioLimit
        )
    }

    func details() -> TorrentDetails {
        var files: [FileStatus] = []
        var pieceMap: [Float] = []
        if let info {
            let pieceLength = Int64(info.pieceLength)
            for (i, file) in info.files.enumerated() where !file.isPadding {
                var done: Int64 = 0
                if file.length > 0 {
                    let first = Int(file.offset / pieceLength)
                    let last = Int((file.offset + file.length - 1) / pieceLength)
                    for piece in first...last where have[piece] {
                        let start = max(Int64(piece) * pieceLength, file.offset)
                        let end = min(Int64(piece) * pieceLength + Int64(info.pieceSize(piece)), file.offset + file.length)
                        done += max(end - start, 0)
                    }
                }
                files.append(FileStatus(id: i, path: file.relativePath, length: file.length, downloaded: done, priority: filePriorities[i]))
            }
            let buckets = min(info.pieceCount, 600)
            pieceMap = (0..<buckets).map { b in
                let start = b * info.pieceCount / buckets
                let end = max((b + 1) * info.pieceCount / buckets, start + 1)
                var sum: Float = 0
                for p in start..<end {
                    if have[p] { sum += 1 } else if let piece = active[p] { sum += Float(piece.receivedCount) / Float(piece.blocks.count) * 0.5 }
                }
                return sum / Float(end - start)
            }
        }
        let peerList = peers.values.filter(\.handshaken).map { peer -> PeerStatus in
            var flags = ""
            if peer.amInterested { flags += peer.peerChoking ? "d" : "D" }
            if peer.peerInterested { flags += peer.amChoking ? "u" : "U" }
            if peer.connection.isIncoming { flags += "I" }
            if peer.source == .pex { flags += "X" }
            if peer.source == .dht { flags += "H" }
            if peer.snubbed { flags += "S" }
            if optimistic == ObjectIdentifier(peer) { flags += "O" }
            let progress = peer.hasAll ? 1 : (peer.bitfield?.fraction ?? 0)
            return PeerStatus(address: peer.address, client: peer.client ?? "Unknown", progress: progress,
                              downloadRate: peer.download.rate, uploadRate: peer.upload.rate,
                              downloaded: peer.download.total, uploaded: peer.upload.total,
                              isIncoming: peer.connection.isIncoming, source: peer.source, flags: flags)
        }.sorted { ($0.downloadRate + $0.uploadRate, $0.progress) > ($1.downloadRate + $1.uploadRate, $1.progress) }
        let trackerList = trackers.map { t in
            let status: String
            switch t.status {
            case .idle: status = isRunning ? "Waiting" : "Not contacted"
            case .announcing: status = "Announcing…"
            case .working: status = "Working"
            case .failed: status = "Not working"
            case .unsupported: status = "Unsupported"
            }
            return TrackerStatus(url: t.url, tier: t.tier, status: status, message: t.message, seeders: t.seeders, leechers: t.leechers,
                                 peers: t.lastPeerCount, lastAnnounce: t.lastAnnounce, nextAnnounce: isRunning && t.client != nil ? t.nextAnnounce : nil)
        }
        return TorrentDetails(id: infoHash, files: files, peers: peerList, trackers: trackerList, pieceMap: pieceMap,
                              pieceCount: info?.pieceCount ?? 0, pieceLength: info?.pieceLength ?? 0,
                              comment: comment, createdBy: createdBy, creationDate: creationDate, webSeeds: webSeeds)
    }

    /// Moves downloaded files to a new folder, pausing transfers while they move.
    func move(to newPath: URL, completion: @escaping (Error?) -> Void) {
        guard newPath.standardizedFileURL != savePath.standardizedFileURL else { completion(nil); return }
        let resumeAfter = !userPaused
        userPaused = true
        syncRunning()
        let old = savePath
        let name = info?.name ?? ""
        session.diskQueue.async { [weak self] in
            self?.storage?.closeAll()
            var failure: Error?
            if !name.isEmpty {
                let from = old.appendingPathComponent(name), to = newPath.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: from.path) {
                    do {
                        try FileManager.default.createDirectory(at: newPath, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: from, to: to)
                    } catch { failure = error }
                }
            }
            self?.session.queue.async { [weak self] in
                guard let self else { return }
                if failure == nil {
                    savePath = newPath
                    if let info { storage = Storage(info: info, root: newPath) }
                }
                userPaused = !resumeAfter
                resumeDirty = true
                session.scheduleQueue()
                completion(failure)
            }
        }
    }

    func trashData(completion: @escaping () -> Void) {
        let url = info.map { savePath.appendingPathComponent($0.name) }
        session.diskQueue.async { [storage] in
            storage?.closeAll()
            if let url, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            completion()
        }
    }
}

/// Parses a dotted IPv4 literal into a host-order integer.
func IPv4Literal(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var v: UInt32 = 0
    for p in parts {
        guard let n = UInt32(p), n < 256 else { return nil }
        v = v << 8 | n
    }
    return v
}

/// A flag the engine sets to stop work running on another queue.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
