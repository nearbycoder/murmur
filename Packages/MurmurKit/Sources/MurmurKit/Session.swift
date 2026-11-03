import Foundation
import Network

public enum SessionError: LocalizedError {
    case alreadyAdded(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name): "“\(name)” is already in your transfers."
        case .notFound: "That transfer no longer exists."
        }
    }
}

/// The BitTorrent session: owns every torrent, the listening port, the DHT and port mapping.
/// Public methods are safe to call from any thread except the session's own queues; updates
/// arrive on the main queue.
public final class Session: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var downloadDirectory: URL
        /// Where torrents and resume data are kept between launches.
        public var stateDirectory: URL
        /// The TCP and UDP port to listen on. Zero picks a random high port.
        public var listenPort: UInt16 = 0
        public var enableDHT = true
        public var enablePEX = true
        public var enablePortMapping = true
        /// Bytes per second; zero means unlimited.
        public var maxDownloadRate = 0
        public var maxUploadRate = 0
        public var maxPeersPerTorrent = 60
        public var maxConnections = 400
        /// How many torrents download at once; zero means no limit.
        public var maxActiveDownloads = 4
        public var uploadSlotsPerTorrent = 6
        /// Stop seeding at this upload ratio; nil seeds forever.
        public var seedRatioLimit: Double?
        public var seedWhenComplete = true
        /// Only use this network interface (a VPN's utun, say). Nil uses any.
        public var networkInterface: String?
        /// BitTorrent protocol encryption (MSE/PE).
        public var encryption: EncryptionMode = .preferred
        /// Find peers on the local network (BEP 14).
        public var enableLocalDiscovery = true
        /// Trackers added to every public torrent, to find more peers.
        public var extraTrackers: [String] = []

        public init(downloadDirectory: URL, stateDirectory: URL) {
            self.downloadDirectory = downloadDirectory
            self.stateDirectory = stateDirectory
        }
    }

    let queue = DispatchQueue(label: "dev.nearby.murmur.engine", qos: .userInitiated)
    let diskQueue = DispatchQueue(label: "dev.nearby.murmur.disk", qos: .utility)
    private(set) var config: Configuration
    let peerID = PeerIdentity.generate()
    private(set) var listenPort: UInt16 = 0
    private(set) var dht: DHT?
    let downloadLimiter = RateLimiter()
    let uploadLimiter = RateLimiter()
    var halfOpen = 0
    var incomingConnections = 0
    private(set) var requiredInterface: NWInterface?
    private var interfaceMissing = false

    private var listener: NWListener?
    private var isListening = false
    private var pendingIncoming: [ObjectIdentifier: PeerConnection] = [:]
    private var torrents: [InfoHash: Torrent] = [:]
    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var portMapper: PortMapper?
    private var localDiscovery: LocalDiscovery?
    private var lsdAnnounced: [InfoHash: Date] = [:]
    private var portMappingStatus: String?
    private var downloadMeter = RateMeter()
    private var uploadMeter = RateMeter()
    private var queueScheduled = false
    private var started = false
    private var ticks = 0

    /// Called on the main queue about once a second.
    public var onUpdate: (([TorrentStatus], SessionStats) -> Void)?
    /// Called on the main queue when a torrent finishes, gets its metadata or fails.
    public var onEvent: ((SessionEvent) -> Void)?

    public init(configuration: Configuration) {
        config = configuration
        downloadLimiter.bytesPerSecond = configuration.maxDownloadRate
        uploadLimiter.bytesPerSecond = configuration.maxUploadRate
    }

    private var torrentsDirectory: URL { config.stateDirectory.appendingPathComponent("Torrents", isDirectory: true) }

    // MARK: - Starting and stopping

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            try? FileManager.default.createDirectory(at: torrentsDirectory, withIntermediateDirectories: true)
            startPathMonitor()
            openPort(config.listenPort)
            loadTorrents()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            applyQueue()
            publish()
        }
    }

    /// Saves everything and tells trackers we're leaving. Calls back on the main queue.
    public func shutdown(completion: @escaping () -> Void) {
        queue.async { [self] in
            timer?.cancel()
            for torrent in torrents.values {
                saveResume(torrent)
                torrent.shutdownForQuit()
            }
            saveDHT()
            dht?.stop()
            listener?.cancel()
            portMapper?.stop()
            localDiscovery?.stop()
            // Give the "stopped" announces a moment to leave.
            queue.asyncAfter(deadline: .now() + 1.2) {
                self.diskQueue.async {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    public func update(configuration: Configuration) {
        queue.async { [self] in
            let old = config
            config = configuration
            downloadLimiter.bytesPerSecond = configuration.maxDownloadRate
            uploadLimiter.bytesPerSecond = configuration.maxUploadRate
            guard started else { return }
            if old.listenPort != configuration.listenPort && configuration.listenPort != 0 && configuration.listenPort != listenPort {
                openPort(configuration.listenPort)
            } else if old.enableDHT != configuration.enableDHT || old.enablePortMapping != configuration.enablePortMapping || old.enableLocalDiscovery != configuration.enableLocalDiscovery {
                openPort(listenPort)
            }
            if old.networkInterface != configuration.networkInterface { refreshInterface(pathMonitor?.currentPath) }
            applyQueue()
        }
    }

    private func openPort(_ requested: UInt16) {
        listener?.cancel()
        listener = nil
        isListening = false
        saveDHT()
        dht?.stop()
        dht = nil
        portMapper?.stop()
        portMapper = nil
        portMappingStatus = nil

        // Bind the DHT's UDP socket first: it fails synchronously if the port is taken.
        var port = requested == 0 ? UInt16.random(in: 49160...65000) : requested
        var udp: DHT?
        for attempt in 0..<6 {
            do {
                if config.enableDHT {
                    let saved = loadDHTState()
                    udp = try DHT(port: port, nodeID: saved?.nodeID, queue: queue, interfaceIndex: interfaceIndex)
                }
                break
            } catch {
                if attempt == 5 { break }
                port = UInt16.random(in: 49160...65000)
            }
        }
        listenPort = port
        dht = udp
        if let dht {
            dht.start(knownNodes: loadDHTState()?.nodes ?? [])
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        if let requiredInterface { parameters.requiredInterface = requiredInterface }
        if let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: parameters, on: nwPort) {
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: isListening = true
                case .failed, .cancelled: isListening = false
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        }

        localDiscovery?.stop()
        localDiscovery = nil
        if config.enableLocalDiscovery, let discovery = try? LocalDiscovery(queue: queue) {
            discovery.onPeer = { [weak self] hash, peer in
                guard let self, let torrent = torrents[hash], torrent.isRunning, !torrent.isPrivate else { return }
                torrent.addPeers([peer], source: .lsd)
            }
            localDiscovery = discovery
            lsdAnnounced = [:]
        }

        if config.enablePortMapping {
            let mapper = PortMapper(port: port, queue: queue)
            mapper.onChange = { [weak self] status in self?.portMappingStatus = status }
            mapper.start()
            portMapper = mapper
        }
    }

    private var interfaceIndex: UInt32? {
        guard let name = config.networkInterface, !name.isEmpty else { return nil }
        let index = if_nametoindex(name)
        return index == 0 ? nil : index
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.refreshInterface(path) }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Binds to the chosen interface, and stops connecting while it's gone (a VPN kill switch).
    private func refreshInterface(_ path: NWPath?) {
        guard let name = config.networkInterface, !name.isEmpty else {
            let changed = requiredInterface != nil || interfaceMissing
            requiredInterface = nil
            interfaceMissing = false
            if changed && started { openPort(listenPort) }
            return
        }
        let found = path?.availableInterfaces.first { $0.name == name }
        let changed = found?.name != requiredInterface?.name || (found == nil) != interfaceMissing
        requiredInterface = found
        interfaceMissing = found == nil
        if interfaceMissing {
            for torrent in torrents.values { torrent.dropAllPeers() }
        }
        if changed && started { openPort(listenPort) }
    }

    private func accept(_ connection: NWConnection) {
        guard !interfaceMissing, totalConnections < config.maxConnections + 20 else { connection.cancel(); return }
        let peer = PeerConnection(incoming: connection, queue: queue)
        peer.incomingMode = config.encryption
        peer.incomingLookup = { [weak self] req2 in self?.torrentForMSE(req2) }
        let id = ObjectIdentifier(peer)
        pendingIncoming[id] = peer
        peer.onHandshake = { [weak self, weak peer] handshake in
            guard let self, let peer else { return false }
            pendingIncoming[id] = nil
            guard let torrent = torrents[handshake.infoHash] else { return false }
            return torrent.accept(peer, handshake: handshake)
        }
        peer.onClose = { [weak self] _ in self?.pendingIncoming[id] = nil }
        peer.start()
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak peer] in
            guard let self, let peer, pendingIncoming[id] != nil else { return }
            pendingIncoming[id] = nil
            peer.close()
        }
    }

    /// Finds the torrent an encrypted incoming connection is for, from HASH("req2", info hash).
    private func torrentForMSE(_ req2: Data) -> InfoHash? {
        torrents.keys.first { (Data("req2".utf8) + $0.bytes).sha1() == req2 }
    }

    // MARK: - Shared limits

    var totalConnections: Int { torrents.values.reduce(0) { $0 + $1.peerCount } + pendingIncoming.count }

    /// How many new outgoing connections may be opened right now.
    func connectionBudget() -> Int {
        guard !interfaceMissing else { return 0 }
        return max(0, min(config.maxConnections - totalConnections, 40 - halfOpen))
    }

    func recordDownload(_ bytes: Int) { downloadMeter.add(bytes) }
    func recordUpload(_ bytes: Int) { uploadMeter.add(bytes) }

    func emit(_ event: SessionEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    // MARK: - Adding and removing

    /// Adds a .torrent file. Throws if it's invalid or already added (new trackers are merged in).
    @discardableResult
    public func addTorrent(data: Data, saveTo directory: URL? = nil, paused: Bool = false, filePriorities: [FilePriority]? = nil) throws -> InfoHash {
        let meta = try Metainfo(data: data)
        return try queue.sync {
            if let existing = torrents[meta.info.infoHash] {
                existing.addTrackers(meta.trackers.flatMap { $0 })
                throw SessionError.alreadyAdded(existing.name)
            }
            let torrent = Torrent(session: self, infoHash: meta.info.infoHash, info: meta.info, trackers: meta.trackers, savePath: directory ?? config.downloadDirectory)
            torrent.webSeeds = meta.webSeeds
            torrent.comment = meta.comment
            torrent.createdBy = meta.createdBy
            torrent.creationDate = meta.creationDate
            if let filePriorities { torrent.restore(have: nil, priorities: filePriorities) }
            torrent.userPaused = paused
            if !meta.info.isPrivate { addExtraTrackers(to: torrent) }
            insert(torrent)
            saveTorrentFile(torrent)
            // Data from an earlier download may already be there.
            if FileManager.default.fileExists(atPath: (directory ?? config.downloadDirectory).appendingPathComponent(meta.info.name).path) {
                torrent.startCheck()
            }
            saveResume(torrent)
            applyQueue()
            return torrent.infoHash
        }
    }

    @discardableResult
    public func addMagnet(_ magnet: MagnetLink, saveTo directory: URL? = nil, paused: Bool = false) throws -> InfoHash {
        try queue.sync {
            if let existing = torrents[magnet.infoHash] {
                existing.addTrackers(magnet.trackers)
                throw SessionError.alreadyAdded(existing.name)
            }
            let torrent = Torrent(session: self, infoHash: magnet.infoHash, info: nil, trackers: magnet.trackers.map { [$0] }, savePath: directory ?? config.downloadDirectory)
            torrent.displayName = magnet.displayName
            torrent.webSeeds = magnet.webSeeds
            torrent.userPaused = paused
            torrent.addPeers(magnet.peers, source: .magnet)
            addExtraTrackers(to: torrent)
            insert(torrent)
            saveResume(torrent)
            applyQueue()
            return torrent.infoHash
        }
    }

    private func addExtraTrackers(to torrent: Torrent) {
        let known = Set(torrent.trackerTiers.flatMap { $0 })
        let extra = config.extraTrackers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !known.contains($0) }
        guard !extra.isEmpty else { return }
        torrent.extraTrackers = Set(extra)
        torrent.trackerTiers += extra.map { [$0] }
        torrent.rebuildTrackers()
    }

    private func insert(_ torrent: Torrent) {
        torrent.queuePosition = (torrents.values.map(\.queuePosition).max() ?? -1) + 1
        torrents[torrent.infoHash] = torrent
    }

    public func remove(_ id: InfoHash, deleteData: Bool) {
        queue.async { [self] in
            guard let torrent = torrents.removeValue(forKey: id) else { return }
            torrent.shutdownForQuit()
            // Keep it (and its tracker clients) alive long enough for the "stopped" announce.
            queue.asyncAfter(deadline: .now() + 10) { _ = torrent }
            try? FileManager.default.removeItem(at: torrentFileURL(id))
            try? FileManager.default.removeItem(at: resumeFileURL(id))
            if deleteData { torrent.trashData {} }
            applyQueue()
            publish()
        }
    }

    public func pause(_ ids: [InfoHash]) {
        modify(ids) { $0.userPaused = true }
    }

    public func resume(_ ids: [InfoHash]) {
        modify(ids) { torrent in
            torrent.userPaused = false
            torrent.finishedByRatio = false
            if torrent.state == .error { torrent.setError(nil) }
            // Resuming a torrent that's done but already at its ratio would stop again at once.
            if let limit = torrent.ratioLimit ?? self.config.seedRatioLimit, torrent.isWantedComplete, torrent.ratio >= limit {
                torrent.ratioLimit = -1
            }
        }
    }

    public func pauseAll() { queue.async { [self] in pause(Array(torrents.keys)) } }
    public func resumeAll() { queue.async { [self] in resume(Array(torrents.keys)) } }

    public func recheck(_ ids: [InfoHash]) {
        modify(ids) { torrent in
            torrent.setError(nil)
            torrent.startCheck()
        }
    }

    public func reannounce(_ ids: [InfoHash]) {
        modify(ids) { $0.reannounce() }
    }

    public func setFilePriorities(_ id: InfoHash, _ changes: [Int: FilePriority]) {
        modify([id]) { $0.setFilePriorities(changes) }
    }

    public func setSequential(_ ids: [InfoHash], _ sequential: Bool) {
        modify(ids) { $0.isSequential = sequential }
    }

    /// A per-torrent ratio limit: nil follows the session's, a negative value seeds forever.
    public func setRatioLimit(_ ids: [InfoHash], _ limit: Double?) {
        modify(ids) { torrent in
            torrent.ratioLimit = limit
            if torrent.finishedByRatio { torrent.finishedByRatio = false }
        }
    }

    /// Per-transfer speed limits in bytes per second (zero or nil for unlimited).
    public func setSpeedLimits(_ ids: [InfoHash], download: Int?, upload: Int?) {
        modify(ids) { torrent in
            if let download { torrent.downloadLimiter.bytesPerSecond = max(download, 0) }
            if let upload { torrent.uploadLimiter.bytesPerSecond = max(upload, 0) }
        }
    }

    public func addTrackers(_ id: InfoHash, _ urls: [String]) {
        modify([id]) { $0.addTrackers(urls) }
    }

    public func removeTracker(_ id: InfoHash, _ url: String) {
        modify([id]) { $0.removeTracker(url) }
    }

    public func addPeers(_ id: InfoHash, _ peers: [PeerAddress]) {
        modify([id]) { $0.addPeers(peers, source: .manual) }
    }

    /// Moves the queue position of torrents (lower starts first).
    public func moveInQueue(_ ids: [InfoHash], toTop: Bool) {
        queue.async { [self] in
            let ordered = torrents.values.sorted { $0.queuePosition < $1.queuePosition }
            let moving = ordered.filter { ids.contains($0.infoHash) }
            let rest = ordered.filter { !ids.contains($0.infoHash) }
            for (i, t) in (toTop ? moving + rest : rest + moving).enumerated() {
                t.queuePosition = i
                t.resumeDirty = true
            }
            applyQueue()
        }
    }

    /// Sets the whole queue order: the listed torrents first, in that order, then any others as they were.
    public func setQueueOrder(_ ids: [InfoHash]) {
        queue.async { [self] in
            let listed = ids.compactMap { torrents[$0] }
            let rest = torrents.values.filter { !ids.contains($0.infoHash) }.sorted { $0.queuePosition < $1.queuePosition }
            for (i, t) in (listed + rest).enumerated() where t.queuePosition != i {
                t.queuePosition = i
                t.resumeDirty = true
            }
            applyQueue()
        }
    }

    public func move(_ id: InfoHash, to directory: URL, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard let torrent = torrents[id] else { DispatchQueue.main.async { completion(SessionError.notFound) }; return }
            torrent.move(to: directory) { error in
                self.saveResume(torrent)
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func modify(_ ids: [InfoHash], _ change: @escaping (Torrent) -> Void) {
        queue.async { [self] in
            for id in ids {
                guard let torrent = torrents[id] else { continue }
                change(torrent)
                torrent.resumeDirty = true
                saveResume(torrent)
            }
            applyQueue()
            publish()
        }
    }

    /// A snapshot of every transfer, in queue order.
    public func statuses() -> [TorrentStatus] {
        queue.sync { torrents.values.sorted { $0.queuePosition < $1.queuePosition }.map { $0.status() } }
    }

    public var port: UInt16 { queue.sync { listenPort } }

    public func details(for id: InfoHash) -> TorrentDetails? {
        queue.sync { torrents[id]?.details() }
    }

    public func details(for id: InfoHash, completion: @escaping (TorrentDetails?) -> Void) {
        queue.async { [self] in
            let details = torrents[id]?.details()
            DispatchQueue.main.async { completion(details) }
        }
    }

    /// The .torrent file for a transfer, once its metadata is known.
    public func torrentFile(for id: InfoHash) -> Data? {
        queue.sync { torrents[id]?.metainfo()?.encoded() }
    }

    // MARK: - Queueing

    func scheduleQueue() {
        guard !queueScheduled else { return }
        queueScheduled = true
        queue.async { [self] in
            queueScheduled = false
            applyQueue()
        }
    }

    /// Decides which torrents run: everything not paused, with at most `maxActiveDownloads` downloading.
    private func applyQueue() {
        var slots = config.maxActiveDownloads == 0 ? Int.max : config.maxActiveDownloads
        for torrent in torrents.values.sorted(by: { $0.queuePosition < $1.queuePosition }) {
            if torrent.userPaused || torrent.errorMessage != nil || torrent.isChecking || torrent.finishedByRatio {
                torrent.queued = false
            } else if torrent.needsDownloadSlot {
                torrent.queued = slots <= 0
                if slots > 0 { slots -= 1 }
            } else {
                torrent.queued = false
            }
            torrent.syncRunning()
        }
    }

    // MARK: - Tick and status

    private func tick() {
        ticks += 1
        downloadMeter.tick()
        uploadMeter.tick()
        let now = Date()
        for torrent in torrents.values { torrent.tick(now: now) }
        if ticks % 30 == 0 {
            for torrent in torrents.values where torrent.resumeDirty { saveResume(torrent) }
        }
        if ticks % 300 == 0 { saveDHT() }
        announceLocally(now: now)
        // Try the router again now and then if mapping failed (it may have been asleep, or permission was just granted).
        if ticks % 600 == 0, config.enablePortMapping, portMappingStatus == nil, let mapper = portMapper {
            mapper.stop()
            let fresh = PortMapper(port: listenPort, queue: queue)
            fresh.onChange = { [weak self] status in self?.portMappingStatus = status }
            fresh.start()
            portMapper = fresh
        }
        publish()
    }

    /// Announces running public torrents on the LAN: soon after they start, then every five minutes.
    private func announceLocally(now: Date) {
        guard let localDiscovery else { return }
        let due = torrents.values.filter { t in
            t.isRunning && !t.isPrivate && (lsdAnnounced[t.infoHash].map { now.timeIntervalSince($0) >= 300 } ?? true)
        }
        guard !due.isEmpty else { return }
        for t in due { lsdAnnounced[t.infoHash] = now }
        localDiscovery.announce(due.map(\.infoHash), port: listenPort)
    }

    private func publish() {
        let statuses = torrents.values.sorted { $0.queuePosition < $1.queuePosition }.map { $0.status() }
        var stats = SessionStats()
        stats.downloadRate = downloadMeter.rate
        stats.uploadRate = uploadMeter.rate
        stats.sessionDownloaded = downloadMeter.total
        stats.sessionUploaded = uploadMeter.total
        stats.dhtNodes = dht?.nodeCount ?? 0
        stats.connectedPeers = torrents.values.reduce(0) { $0 + $1.connectedCount }
        stats.listenPort = listenPort
        stats.incomingConnections = incomingConnections
        stats.portMapping = interfaceMissing ? "Waiting for \(config.networkInterface ?? "interface")" : portMappingStatus
        stats.isListening = isListening
        let handler = onUpdate
        DispatchQueue.main.async { handler?(statuses, stats) }
    }

    // MARK: - Persistence

    struct ResumeRecord: Codable {
        var name: String?
        var savePath: String
        var magnet: String?
        var trackers: [[String]]
        var addedDate: Date
        var completedDate: Date?
        var uploaded: Int64
        var downloaded: Int64
        var paused: Bool
        var finished: Bool?
        var sequential: Bool
        var priorities: [Int]?
        var have: Data?
        var fileDates: [Double]?
        var queuePosition: Int
        var ratioLimit: Double?
        var downloadLimit: Int?
        var uploadLimit: Int?
    }

    private func torrentFileURL(_ id: InfoHash) -> URL { torrentsDirectory.appendingPathComponent("\(id.hex).torrent") }
    private func resumeFileURL(_ id: InfoHash) -> URL { torrentsDirectory.appendingPathComponent("\(id.hex).resume") }

    func saveTorrentFile(_ torrent: Torrent) {
        guard let data = torrent.metainfo()?.encoded() else { return }
        try? data.write(to: torrentFileURL(torrent.infoHash), options: .atomic)
    }

    func saveResume(_ torrent: Torrent) {
        guard torrents[torrent.infoHash] === torrent else { return }
        let record = ResumeRecord(
            name: torrent.name,
            savePath: torrent.savePath.path,
            magnet: torrent.info == nil ? MagnetLink(infoHash: torrent.infoHash, displayName: torrent.displayName, trackers: torrent.trackerTiers.flatMap { $0 }, webSeeds: torrent.webSeeds).uri : nil,
            trackers: torrent.trackerTiers,
            addedDate: torrent.addedDate,
            completedDate: torrent.completedDate,
            uploaded: torrent.uploadedTotal,
            downloaded: torrent.downloadedTotal,
            paused: torrent.userPaused,
            finished: torrent.finishedByRatio,
            sequential: torrent.isSequential,
            priorities: torrent.info == nil ? nil : torrent.filePriorities.map(\.rawValue),
            have: torrent.info == nil || torrent.isChecking ? nil : torrent.have.data,
            fileDates: torrent.fileDates(),
            queuePosition: torrent.queuePosition,
            ratioLimit: torrent.ratioLimit,
            downloadLimit: torrent.downloadLimiter.bytesPerSecond,
            uploadLimit: torrent.uploadLimiter.bytesPerSecond
        )
        torrent.resumeDirty = false
        let url = resumeFileURL(torrent.infoHash)
        diskQueue.async {
            // Wait for pending writes so the file dates match what's recorded.
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func loadTorrents() {
        let files = (try? FileManager.default.contentsOfDirectory(at: torrentsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "resume" {
            guard let hash = InfoHash(string: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(ResumeRecord.self, from: data) else { continue }
            var info: TorrentInfo?
            var meta: Metainfo?
            if let torrentData = try? Data(contentsOf: torrentFileURL(hash)), let parsed = try? Metainfo(data: torrentData), parsed.info.infoHash == hash {
                meta = parsed
                info = parsed.info
            }
            guard info != nil || record.magnet != nil else { continue }
            let savedMagnet = record.magnet.flatMap { try? MagnetLink($0) }
            let torrent = Torrent(session: self, infoHash: hash, info: info, trackers: record.trackers, savePath: URL(fileURLWithPath: record.savePath))
            if let meta {
                torrent.webSeeds = meta.webSeeds
                torrent.comment = meta.comment
                torrent.createdBy = meta.createdBy
                torrent.creationDate = meta.creationDate
            }
            torrent.displayName = record.name
            if info == nil, let savedMagnet { torrent.webSeeds = savedMagnet.webSeeds }
            torrent.addedDate = record.addedDate
            torrent.completedDate = record.completedDate
            torrent.uploadedTotal = record.uploaded
            torrent.downloadedTotal = record.downloaded
            torrent.userPaused = record.paused
            torrent.finishedByRatio = record.finished ?? false
            torrent.isSequential = record.sequential
            torrent.queuePosition = record.queuePosition
            torrent.ratioLimit = record.ratioLimit
            torrent.downloadLimiter.bytesPerSecond = record.downloadLimit ?? 0
            torrent.uploadLimiter.bytesPerSecond = record.uploadLimit ?? 0
            if info != nil {
                torrent.restore(have: record.have, priorities: record.priorities?.compactMap(FilePriority.init(rawValue:)))
                torrent.markLoaded()
                if !torrent.validateResume(fileDates: record.fileDates, haveData: record.have) {
                    torrent.startCheck()
                }
            }
            torrents[hash] = torrent
        }
    }

    private struct DHTState: Codable {
        var nodeID: Data
        var nodes: [Data]
    }

    private var dhtStateURL: URL { config.stateDirectory.appendingPathComponent("dht.json") }

    private func loadDHTState() -> (nodeID: Data, nodes: [NodeEndpoint])? {
        guard let data = try? Data(contentsOf: dhtStateURL), let state = try? JSONDecoder().decode(DHTState.self, from: data) else { return nil }
        return (state.nodeID, state.nodes.compactMap { NodeEndpoint(compact: $0) })
    }

    private func saveDHT() {
        guard let dht else { return }
        let state = dht.state()
        guard !state.nodes.isEmpty else { return }
        let record = DHTState(nodeID: state.nodeID, nodes: state.nodes.map(\.compact))
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: dhtStateURL, options: .atomic) }
    }
}
