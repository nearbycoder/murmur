import Foundation
import Network

enum AnnounceEvent: Int32 {
    case none = 0, completed = 1, started = 2, stopped = 3

    var httpValue: String? {
        switch self {
        case .none: nil
        case .completed: "completed"
        case .started: "started"
        case .stopped: "stopped"
        }
    }
}

struct AnnounceRequest {
    let infoHash: InfoHash
    let peerID: Data
    let port: UInt16
    let uploaded: Int64
    let downloaded: Int64
    let left: Int64
    let event: AnnounceEvent
    let numWant: Int
    let key: UInt32
}

struct AnnounceResponse {
    var interval: TimeInterval
    var minInterval: TimeInterval?
    var seeders: Int?
    var leechers: Int?
    var peers: [PeerAddress]
    var warning: String?
    var trackerID: String?
}

enum TrackerError: LocalizedError {
    case failure(String)
    case badResponse
    case timedOut
    case unsupported

    var errorDescription: String? {
        switch self {
        case .failure(let reason): reason
        case .badResponse: "Invalid response"
        case .timedOut: "Timed out"
        case .unsupported: "Unsupported tracker"
        }
    }
}

protocol TrackerClient: AnyObject {
    /// Calls back on the engine queue.
    func announce(_ request: AnnounceRequest, trackerID: String?, completion: @escaping (Result<AnnounceResponse, Error>) -> Void)
    func cancel()
}

/// HTTP and HTTPS trackers (BEP 3, compact peers from BEP 23, IPv6 peers from BEP 7).
final class HTTPTracker: TrackerClient {
    private let url: String
    private let queue: DispatchQueue
    private var task: URLSessionDataTask?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.httpAdditionalHeaders = ["User-Agent": "Murmur/\(PeerIdentity.clientVersion)"]
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    init(url: String, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    func announce(_ request: AnnounceRequest, trackerID: String?, completion: @escaping (Result<AnnounceResponse, Error>) -> Void) {
        var s = url + (url.contains("?") ? "&" : "?")
        s += "info_hash=\(request.infoHash.bytes.urlPercentEncoded)"
        s += "&peer_id=\(request.peerID.urlPercentEncoded)"
        s += "&port=\(request.port)&uploaded=\(request.uploaded)&downloaded=\(request.downloaded)&left=\(request.left)"
        s += "&compact=1&no_peer_id=1&numwant=\(request.numWant)&key=\(String(format: "%08X", request.key))"
        if let event = request.event.httpValue { s += "&event=\(event)" }
        if let trackerID, let encoded = trackerID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { s += "&trackerid=\(encoded)" }
        guard let requestURL = URL(string: s) else {
            queue.async { completion(.failure(TrackerError.unsupported)) }
            return
        }
        task?.cancel()
        let queue = self.queue
        task = HTTPTracker.session.dataTask(with: requestURL) { data, response, error in
            let result: Result<AnnounceResponse, Error>
            if let error {
                result = .failure(error)
            } else if let data {
                result = Result { try HTTPTracker.parse(data) }
            } else {
                result = .failure(TrackerError.badResponse)
            }
            queue.async { completion(result) }
        }
        task?.resume()
    }

    static func parse(_ data: Data) throws -> AnnounceResponse {
        guard let value = try? BencodeDecoder.decode(data), case .dictionary = value else {
            // Some trackers return an HTML error page.
            throw TrackerError.badResponse
        }
        if let reason = value["failure reason"]?.string { throw TrackerError.failure(reason) }
        var peers: [PeerAddress] = []
        if let compact = value["peers"]?.data {
            peers = PeerAddress.parseCompact(compact)
        } else if let list = value["peers"]?.list {
            for item in list {
                if let ip = item["ip"]?.string, let port = item["port"]?.int, port > 0, port < 65536 {
                    let address = PeerAddress(host: ip, port: UInt16(port))
                    if address.isUsable { peers.append(address) }
                }
            }
        }
        if let compact6 = value["peers6"]?.data { peers += PeerAddress.parseCompact(compact6, ipv6: true) }
        return AnnounceResponse(
            interval: TimeInterval(value["interval"]?.int ?? 1800),
            minInterval: value["min interval"]?.int.map(TimeInterval.init),
            seeders: value["complete"]?.int.map(Int.init),
            leechers: value["incomplete"]?.int.map(Int.init),
            peers: peers,
            warning: value["warning message"]?.string,
            trackerID: value["tracker id"]?.string
        )
    }

    func cancel() { task?.cancel() }
}

/// UDP trackers (BEP 15).
final class UDPTracker: TrackerClient {
    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var connectionID: UInt64?
    private var connectionIDDate = Date.distantPast
    private var transaction: UInt32 = 0
    private var pending: ((Data) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Result<AnnounceResponse, Error>) -> Void)?

    init?(url: String, queue: DispatchQueue) {
        guard let components = URLComponents(string: url), let host = components.host, let port = components.port, port > 0, port < 65536 else { return nil }
        self.host = host
        self.port = UInt16(port)
        self.queue = queue
    }

    func announce(_ request: AnnounceRequest, trackerID: String?, completion: @escaping (Result<AnnounceResponse, Error>) -> Void) {
        self.completion = completion
        if connection == nil { openConnection() }
        if let id = connectionID, Date().timeIntervalSince(connectionIDDate) < 55 {
            sendAnnounce(request, connectionID: id, attempt: 0)
        } else {
            sendConnect(attempt: 0) { [weak self] id in
                self?.sendAnnounce(request, connectionID: id, attempt: 0)
            }
        }
    }

    private func openConnection() {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.finish(.failure(error)) }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive()
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { pending?(data) }
            if error == nil { receive() }
        }
    }

    private func nextTransaction() -> UInt32 {
        transaction = UInt32.random(in: 1...UInt32.max)
        return transaction
    }

    private func timeout(for attempt: Int) -> TimeInterval { [4, 8, 12][min(attempt, 2)] }

    private func sendConnect(attempt: Int, then: @escaping (UInt64) -> Void) {
        guard attempt < 3 else { finish(.failure(TrackerError.timedOut)); return }
        let tx = nextTransaction()
        var packet = Data()
        packet.appendUInt64(0x41727101980)
        packet.appendUInt32(0)
        packet.appendUInt32(tx)
        pending = { [weak self] data in
            guard let self, data.count >= 16, data.uint32(at: 4) == tx else { return }
            if data.uint32(at: 0) == 3 { finish(.failure(TrackerError.failure(String(decoding: data.dropFirst(8), as: UTF8.self)))); return }
            guard data.uint32(at: 0) == 0 else { return }
            let id = data.uint64(at: 8)
            connectionID = id
            connectionIDDate = Date()
            timeoutWork?.cancel()
            then(id)
        }
        connection?.send(content: packet, completion: .idempotent)
        schedule(after: timeout(for: attempt)) { [weak self] in self?.sendConnect(attempt: attempt + 1, then: then) }
    }

    private func sendAnnounce(_ request: AnnounceRequest, connectionID: UInt64, attempt: Int) {
        guard attempt < 3 else {
            // The connection id may have expired; start over once with a fresh one.
            self.connectionID = nil
            finish(.failure(TrackerError.timedOut))
            return
        }
        let tx = nextTransaction()
        var packet = Data()
        packet.appendUInt64(connectionID)
        packet.appendUInt32(1)
        packet.appendUInt32(tx)
        packet.append(request.infoHash.bytes)
        packet.append(request.peerID)
        packet.appendUInt64(UInt64(max(request.downloaded, 0)))
        packet.appendUInt64(UInt64(max(request.left, 0)))
        packet.appendUInt64(UInt64(max(request.uploaded, 0)))
        packet.appendUInt32(UInt32(request.event.rawValue))
        packet.appendUInt32(0) // ip
        packet.appendUInt32(request.key)
        packet.appendUInt32(UInt32(bitPattern: Int32(request.numWant)))
        packet.appendUInt16(request.port)
        pending = { [weak self] data in
            guard let self, data.count >= 8, data.uint32(at: 4) == tx else { return }
            let action = data.uint32(at: 0)
            if action == 3 { finish(.failure(TrackerError.failure(String(decoding: data.dropFirst(8), as: UTF8.self)))); return }
            guard action == 1, data.count >= 20 else { return }
            // Over IPv6 the tracker replies with 18-byte IPv6 peers.
            var isV6 = false
            if case .hostPort(.ipv6(let address), _)? = connection?.currentPath?.remoteEndpoint, !address.isIPv4Mapped { isV6 = true }
            let response = AnnounceResponse(
                interval: TimeInterval(data.uint32(at: 8)),
                minInterval: nil,
                seeders: Int(data.uint32(at: 16)),
                leechers: Int(data.uint32(at: 12)),
                peers: PeerAddress.parseCompact(data.dropFirst(20), ipv6: isV6),
                warning: nil,
                trackerID: nil
            )
            finish(.success(response))
        }
        connection?.send(content: packet, completion: .idempotent)
        schedule(after: timeout(for: attempt)) { [weak self] in
            self?.sendAnnounce(request, connectionID: connectionID, attempt: attempt + 1)
        }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem(block: block)
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish(_ result: Result<AnnounceResponse, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        pending = nil
        let completion = self.completion
        self.completion = nil
        if case .failure = result {
            connection?.cancel()
            connection = nil
            connectionID = nil
        }
        completion?(result)
    }

    func cancel() {
        timeoutWork?.cancel()
        pending = nil
        completion = nil
        connection?.cancel()
        connection = nil
    }
}

/// One tracker URL of a torrent and its announce schedule.
final class TrackerEntry {
    enum Status: String { case idle, announcing, working, failed, unsupported }

    let url: String
    let tier: Int
    let client: TrackerClient?
    var status: Status
    var message: String?
    var lastAnnounce: Date?
    var nextAnnounce = Date()
    var interval: TimeInterval = 1800
    var minInterval: TimeInterval = 60
    var seeders: Int?
    var leechers: Int?
    var lastPeerCount = 0
    var failures = 0
    var trackerID: String?

    init(url: String, tier: Int, queue: DispatchQueue) {
        self.url = url
        self.tier = tier
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            client = HTTPTracker(url: url, queue: queue)
        } else if lower.hasPrefix("udp://") {
            client = UDPTracker(url: url, queue: queue)
        } else {
            client = nil
        }
        status = client == nil ? .unsupported : .idle
    }

    var host: String { URLComponents(string: url)?.host ?? url }
}
