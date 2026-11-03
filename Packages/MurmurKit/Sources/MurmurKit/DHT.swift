import Foundation

/// The mainline DHT (BEP 5): finds peers for torrents without trackers, and answers
/// other nodes' queries so the network keeps working.
final class DHT {
    struct Node {
        let id: Data
        let endpoint: NodeEndpoint
        var lastSeen: Date
        var failures = 0
    }

    private let queue: DispatchQueue
    private let socket: UDPSocket
    let nodeID: Data
    private var buckets: [[Node]] = Array(repeating: [], count: 160)
    private var pending: [UInt16: Pending] = [:]
    private var nextTransaction = UInt16.random(in: 0...UInt16.max)
    private var lookups: [ObjectIdentifier: Lookup] = [:]
    private var stored: [InfoHash: [PeerAddress: Date]] = [:]
    private var secret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var previousSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var timer: DispatchSourceTimer?
    private var lastSecretRotation = Date()
    private var lastBootstrap = Date.distantPast
    private let bootstrapHosts: [(String, UInt16)] = [
        ("router.bittorrent.com", 6881), ("dht.transmissionbt.com", 6881),
        ("router.utorrent.com", 6881), ("dht.libtorrent.org", 25401), ("dht.aelitis.com", 6881),
    ]

    private struct Pending {
        let endpoint: NodeEndpoint
        let sent: Date
        let callback: (BencodeValue?) -> Void
    }

    private static let k = 8

    var nodeCount: Int { buckets.reduce(0) { $0 + $1.count } }

    init(port: UInt16, nodeID: Data?, queue: DispatchQueue, interfaceIndex: UInt32? = nil) throws {
        self.queue = queue
        self.nodeID = nodeID?.count == 20 ? nodeID! : Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        socket = try UDPSocket(port: port, queue: queue, interfaceIndex: interfaceIndex)
        socket.onPacket = { [weak self] data, from in self?.handle(data, from: from) }
    }

    func start(knownNodes: [NodeEndpoint]) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        if !knownNodes.isEmpty { findNode(target: nodeID, seeds: knownNodes) }
        bootstrap()
    }

    func stop() {
        timer?.cancel()
        socket.close()
        lookups.removeAll()
        pending.removeAll()
    }

    /// Up to 300 good nodes and our id, to restart quickly next time.
    func state() -> (nodeID: Data, nodes: [NodeEndpoint]) {
        let nodes = buckets.flatMap { $0 }.filter { $0.failures == 0 }.sorted { $0.lastSeen > $1.lastSeen }.prefix(300).map(\.endpoint)
        return (nodeID, Array(nodes))
    }

    /// Adds a node we learned about from a peer's PORT message.
    func ping(_ endpoint: NodeEndpoint) {
        guard endpoint.isValid else { return }
        query("ping", args: [:], to: endpoint) { _ in }
    }

    /// Looks up peers for a torrent, reporting them as they arrive, then announces us when `announcePort` is set.
    func getPeers(_ infoHash: InfoHash, announcePort: UInt16?, onPeers: @escaping ([PeerAddress]) -> Void, onDone: @escaping () -> Void) {
        if nodeCount < 8 { bootstrap() }
        let lookup = Lookup(target: infoHash.bytes, getPeers: true)
        lookup.onPeers = onPeers
        lookup.onDone = { [weak self, weak lookup] in
            guard let self, let lookup else { return }
            if let port = announcePort {
                for candidate in lookup.closestResponded(DHT.k) {
                    guard let token = candidate.token else { continue }
                    query("announce_peer", args: [
                        "info_hash": .bytes(infoHash.bytes), "port": .integer(Int64(port)),
                        "token": .bytes(token), "implied_port": .integer(1),
                    ], to: candidate.endpoint) { _ in }
                }
            }
            onDone()
        }
        start(lookup, seeds: closest(to: infoHash.bytes, count: 16).map { ($0.id, $0.endpoint) })
    }

    // MARK: - Lookups

    private final class Lookup {
        struct Candidate {
            let id: Data?
            let endpoint: NodeEndpoint
            let distance: Data
            var state: State = .new
            var token: Data?
        }
        enum State { case new, inFlight, responded, failed }

        let target: Data
        let getPeers: Bool
        var candidates: [Candidate] = []
        var seen = Set<NodeEndpoint>()
        var inFlight = 0
        var started = Date()
        var finished = false
        var peersFound = Set<PeerAddress>()
        var onPeers: (([PeerAddress]) -> Void)?
        var onDone: (() -> Void)?

        init(target: Data, getPeers: Bool) {
            self.target = target
            self.getPeers = getPeers
        }

        func add(id: Data?, endpoint: NodeEndpoint) {
            guard endpoint.isValid, !seen.contains(endpoint), candidates.count < 400 else { return }
            seen.insert(endpoint)
            // Unknown ids (bootstrap routers) sort first so they're asked straight away.
            let distance = id.map { DHT.xor($0, target) } ?? Data(count: 20)
            let candidate = Candidate(id: id, endpoint: endpoint, distance: distance)
            let index = candidates.firstIndex { !$0.distance.lexicographicallyPrecedes(distance) && $0.distance != distance } ?? candidates.count
            candidates.insert(candidate, at: index)
        }

        func closestResponded(_ count: Int) -> [Candidate] {
            Array(candidates.filter { $0.state == .responded && $0.id != nil }.prefix(count))
        }

        /// Done when the closest k live nodes have all answered.
        var isConverged: Bool {
            var answered = 0
            for c in candidates where c.state != .failed {
                if c.state != .responded { return false }
                answered += 1
                if answered >= DHT.k { return true }
            }
            return inFlight == 0
        }
    }

    private func findNode(target: Data, seeds: [NodeEndpoint]) {
        let lookup = Lookup(target: target, getPeers: false)
        start(lookup, seeds: seeds.map { (nil, $0) } + closest(to: target, count: 8).map { ($0.id, $0.endpoint) })
    }

    private func start(_ lookup: Lookup, seeds: [(Data?, NodeEndpoint)]) {
        for (id, endpoint) in seeds { lookup.add(id: id, endpoint: endpoint) }
        lookups[ObjectIdentifier(lookup)] = lookup
        step(lookup)
    }

    private func step(_ lookup: Lookup) {
        guard !lookup.finished else { return }
        if Date().timeIntervalSince(lookup.started) > 40 || (lookup.inFlight == 0 && !lookup.candidates.contains { $0.state == .new }) || (lookup.isConverged && lookup.candidates.count >= DHT.k) {
            finish(lookup)
            return
        }
        let alpha = 6
        var considered = 0
        for i in lookup.candidates.indices {
            guard lookup.inFlight < alpha else { break }
            if lookup.candidates[i].state == .failed { continue }
            considered += 1
            // Only widen past the closest few when they're still being asked.
            if considered > DHT.k * 2 { break }
            guard lookup.candidates[i].state == .new else { continue }
            lookup.candidates[i].state = .inFlight
            lookup.inFlight += 1
            let endpoint = lookup.candidates[i].endpoint
            let method = lookup.getPeers ? "get_peers" : "find_node"
            let args: [String: BencodeValue] = lookup.getPeers ? ["info_hash": .bytes(lookup.target)] : ["target": .bytes(lookup.target)]
            query(method, args: args, to: endpoint) { [weak self, weak lookup] response in
                guard let self, let lookup else { return }
                lookup.inFlight -= 1
                guard let index = lookup.candidates.firstIndex(where: { $0.endpoint == endpoint }) else { return }
                if let response {
                    lookup.candidates[index].state = .responded
                    lookup.candidates[index].token = response["token"]?.data
                    if let nodes = response["nodes"]?.data {
                        for (id, ep) in DHT.parseNodes(nodes) where id != nodeID { lookup.add(id: id, endpoint: ep) }
                    }
                    if let values = response["values"]?.list {
                        let peers = values.compactMap(\.data).flatMap { PeerAddress.parseCompact($0) }.filter { lookup.peersFound.insert($0).inserted }
                        if !peers.isEmpty { lookup.onPeers?(peers) }
                    }
                } else {
                    lookup.candidates[index].state = .failed
                }
                step(lookup)
            }
        }
        if lookup.inFlight == 0 { finish(lookup) }
    }

    private func finish(_ lookup: Lookup) {
        guard !lookup.finished else { return }
        lookup.finished = true
        lookups[ObjectIdentifier(lookup)] = nil
        lookup.onDone?()
    }

    // MARK: - Messages

    private func query(_ method: String, args: [String: BencodeValue], to endpoint: NodeEndpoint, callback: @escaping (BencodeValue?) -> Void) {
        nextTransaction &+= 1
        let tx = nextTransaction
        var a = args
        a["id"] = .bytes(nodeID)
        var t = Data()
        t.appendUInt16(tx)
        let message = BencodeValue.dictionary(["t": .bytes(t), "y": BencodeValue("q"), "q": BencodeValue(method), "a": .dictionary(a), "v": .bytes(Data("MU10".utf8))])
        pending[tx] = Pending(endpoint: endpoint, sent: Date(), callback: callback)
        socket.send(message.encoded(), to: endpoint)
    }

    private func handle(_ data: Data, from: NodeEndpoint) {
        guard let message = try? BencodeDecoder.decode(data), let y = message["y"]?.string else { return }
        switch y {
        case "r", "e":
            guard let t = message["t"]?.data, t.count == 2 else { return }
            let tx = t.uint16(at: 0)
            guard let p = pending[tx], p.endpoint == from else { return }
            pending[tx] = nil
            if y == "r", let r = message["r"], let id = r["id"]?.data, id.count == 20 {
                insert(id: id, endpoint: from)
                p.callback(r)
            } else {
                p.callback(nil)
            }
        case "q":
            respond(to: message, from: from)
        default:
            break
        }
    }

    private func respond(to message: BencodeValue, from: NodeEndpoint) {
        guard let t = message["t"]?.data, let q = message["q"]?.string, let a = message["a"], let id = a["id"]?.data, id.count == 20 else { return }
        if a["ro"]?.int != 1 { insert(id: id, endpoint: from) }
        var r: [String: BencodeValue] = ["id": .bytes(nodeID)]
        switch q {
        case "ping":
            break
        case "find_node":
            guard let target = a["target"]?.data, target.count == 20 else { return error(t, 203, "Bad target", to: from) }
            r["nodes"] = .bytes(compactNodes(closest(to: target, count: DHT.k)))
        case "get_peers":
            guard let hashData = a["info_hash"]?.data, let hash = InfoHash(bytes: hashData) else { return error(t, 203, "Bad info_hash", to: from) }
            r["token"] = .bytes(token(for: from, secret: secret))
            let peers = (stored[hash] ?? [:]).keys.prefix(50).compactMap(\.compact)
            if peers.isEmpty {
                r["nodes"] = .bytes(compactNodes(closest(to: hashData, count: DHT.k)))
            } else {
                r["values"] = .list(peers.map { .bytes($0) })
            }
        case "announce_peer":
            guard let hashData = a["info_hash"]?.data, let hash = InfoHash(bytes: hashData), let tok = a["token"]?.data else { return error(t, 203, "Bad announce", to: from) }
            guard tok == token(for: from, secret: secret) || tok == token(for: from, secret: previousSecret) else { return error(t, 203, "Bad token", to: from) }
            let implied = a["implied_port"]?.int == 1
            let port = implied ? from.port : UInt16(clamping: a["port"]?.int ?? 0)
            guard port != 0 else { return }
            var peers = stored[hash] ?? [:]
            if peers.count < 200 { peers[PeerAddress(host: from.peerAddress.host, port: port)] = Date() }
            if stored.count < 2000 || stored[hash] != nil { stored[hash] = peers }
        default:
            return error(t, 204, "Method Unknown", to: from)
        }
        let reply = BencodeValue.dictionary(["t": .bytes(t), "y": BencodeValue("r"), "r": .dictionary(r), "v": .bytes(Data("MU10".utf8))])
        socket.send(reply.encoded(), to: from)
    }

    private func error(_ t: Data, _ code: Int, _ text: String, to: NodeEndpoint) {
        let reply = BencodeValue.dictionary(["t": .bytes(t), "y": BencodeValue("e"), "e": .list([.integer(Int64(code)), BencodeValue(text)])])
        socket.send(reply.encoded(), to: to)
    }

    private func token(for endpoint: NodeEndpoint, secret: Data) -> Data {
        (secret + endpoint.ipBytes).sha1().prefix(8)
    }

    // MARK: - Routing table

    static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    private func bucketIndex(for id: Data) -> Int {
        let d = DHT.xor(id, nodeID)
        for (i, byte) in d.enumerated() where byte != 0 {
            return min(i * 8 + byte.leadingZeroBitCount, 159)
        }
        return 159
    }

    private func insert(id: Data, endpoint: NodeEndpoint) {
        guard id != nodeID, endpoint.isValid else { return }
        let b = bucketIndex(for: id)
        if let i = buckets[b].firstIndex(where: { $0.id == id }) {
            buckets[b][i].lastSeen = Date()
            buckets[b][i].failures = 0
            return
        }
        // One entry per address, so a node can't take over a bucket.
        if buckets[b].contains(where: { $0.endpoint == endpoint }) { return }
        if buckets[b].count < DHT.k {
            buckets[b].append(Node(id: id, endpoint: endpoint, lastSeen: Date()))
        } else if let worst = buckets[b].indices.max(by: { buckets[b][$0].failures < buckets[b][$1].failures }), buckets[b][worst].failures > 0 {
            buckets[b][worst] = Node(id: id, endpoint: endpoint, lastSeen: Date())
        }
    }

    private func closest(to target: Data, count: Int) -> [Node] {
        let all = buckets.flatMap { $0 }.filter { $0.failures < 3 }
        return Array(all.sorted { DHT.xor($0.id, target).lexicographicallyPrecedes(DHT.xor($1.id, target)) }.prefix(count))
    }

    private func compactNodes(_ nodes: [Node]) -> Data {
        nodes.reduce(into: Data()) { $0.append($1.id); $0.append($1.endpoint.compact) }
    }

    static func parseNodes(_ data: Data) -> [(Data, NodeEndpoint)] {
        var out: [(Data, NodeEndpoint)] = []
        var i = data.startIndex
        while i + 26 <= data.endIndex {
            let id = data.subdata(in: i ..< i + 20)
            if let ep = NodeEndpoint(compact: data.subdata(in: i + 20 ..< i + 26)) { out.append((id, ep)) }
            i += 26
        }
        return out
    }

    private func markFailed(_ endpoint: NodeEndpoint) {
        for b in buckets.indices {
            if let i = buckets[b].firstIndex(where: { $0.endpoint == endpoint }) {
                buckets[b][i].failures += 1
                if buckets[b][i].failures >= 4 { buckets[b].remove(at: i) }
                return
            }
        }
    }

    // MARK: - Maintenance

    private func tick() {
        let now = Date()
        for (tx, p) in pending where now.timeIntervalSince(p.sent) > 3 {
            pending[tx] = nil
            markFailed(p.endpoint)
            p.callback(nil)
        }
        if now.timeIntervalSince(lastSecretRotation) > 300 {
            previousSecret = secret
            secret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            lastSecretRotation = now
            for (hash, peers) in stored {
                let fresh = peers.filter { now.timeIntervalSince($0.value) < 1800 }
                stored[hash] = fresh.isEmpty ? nil : fresh
            }
        }
        // Keep the table filled; refresh more often while it's small.
        let interval: TimeInterval = nodeCount < 30 ? 30 : 600
        if now.timeIntervalSince(lastBootstrap) > interval {
            bootstrap()
        }
    }

    private func bootstrap() {
        guard Date().timeIntervalSince(lastBootstrap) > 10 else { return }
        lastBootstrap = Date()
        if nodeCount >= 30 {
            // Alternate between our own neighborhood and a random corner of the keyspace.
            var target = nodeID
            if Bool.random() {
                target = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
            } else {
                for i in 4..<20 { target[i] = UInt8.random(in: 0...255) }
            }
            findNode(target: target, seeds: [])
            return
        }
        let hosts = bootstrapHosts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var endpoints: [NodeEndpoint] = []
            for (host, port) in hosts { endpoints += DHT.resolve(host, port: port) }
            self?.queue.async { [weak self] in
                guard let self else { return }
                findNode(target: nodeID, seeds: endpoints)
            }
        }
    }

    static func resolve(_ host: String, port: UInt16) -> [NodeEndpoint] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [NodeEndpoint] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let addr = info.pointee.ai_addr {
                let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                out.append(NodeEndpoint(sin))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}
