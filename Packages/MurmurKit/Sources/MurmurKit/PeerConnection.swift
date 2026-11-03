import Foundation
import Network

/// A TCP connection to one peer: the handshake, then length-prefixed messages.
/// Everything runs on the session's engine queue.
final class PeerConnection {
    enum Failure: Error { case protocolError(String), closedByPeer, timedOut }

    let queue: DispatchQueue
    let isIncoming: Bool
    private let connection: NWConnection
    private var buffer = Data()
    private var readOffset = 0
    private var gotHandshake = false
    private var closed = false

    /// Return false to drop the connection (wrong torrent, ourselves, banned).
    var onHandshake: ((Handshake) -> Bool)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClose: ((Error?) -> Void)?
    var onConnected: (() -> Void)?
    /// Called after queued data has gone out, so uploads can keep the pipe full.
    var onDrain: (() -> Void)?

    var downloadLimiter: RateLimiter?
    private(set) var queuedSendBytes = 0
    private(set) var isConnected = false
    private(set) var lastReceived = Date()
    private(set) var lastSent = Date()

    init(address: PeerAddress, queue: DispatchQueue, requiredInterface: NWInterface? = nil) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        tcp.enableKeepalive = false
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let requiredInterface { parameters.requiredInterface = requiredInterface }
        connection = NWConnection(to: address.endpoint, using: parameters)
        self.queue = queue
        isIncoming = false
    }

    init(incoming: NWConnection, queue: DispatchQueue) {
        connection = incoming
        self.queue = queue
        isIncoming = true
    }

    var remoteEndpoint: NWEndpoint { connection.endpoint }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !isConnected else { return }
                isConnected = true
                onConnected?()
                receive()
            case .waiting(let error), .failed(let error):
                fail(error)
            case .cancelled:
                fail(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func sendHandshake(_ handshake: Handshake) {
        write(handshake.encoded())
    }

    func send(_ message: PeerMessage) {
        write(message.encoded())
    }

    private func write(_ data: Data) {
        guard !closed else { return }
        queuedSendBytes += data.count
        lastSent = Date()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            queuedSendBytes -= data.count
            if let error { fail(error); return }
            onDrain?()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose = nil
        onMessage = nil
        onHandshake = nil
        onDrain = nil
    }

    private func fail(_ error: Error?) {
        guard !closed else { return }
        let handler = onClose
        close()
        handler?(error)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !closed else { return }
            if let data, !data.isEmpty {
                lastReceived = Date()
                buffer.append(data)
                process()
                if closed { return }
                let wait = downloadLimiter?.consume(data.count) ?? 0
                if isComplete { fail(Failure.closedByPeer); return }
                if let error { fail(error); return }
                if wait > 0 {
                    queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.receive() }
                } else {
                    receive()
                }
                return
            }
            if let error { fail(error); return }
            if isComplete { fail(Failure.closedByPeer); return }
            receive()
        }
    }

    private func process() {
        while !closed {
            let available = buffer.count - readOffset
            if !gotHandshake {
                guard available >= 68 else { break }
                let start = buffer.startIndex + readOffset
                guard let handshake = Handshake.parse(buffer.subdata(in: start ..< start + 68)) else {
                    fail(Failure.protocolError("bad handshake")); return
                }
                readOffset += 68
                gotHandshake = true
                if onHandshake?(handshake) == false { close(); return }
                continue
            }
            guard available >= 4 else { break }
            let start = buffer.startIndex + readOffset
            let length = Int(buffer.uint32(at: readOffset))
            guard length <= PeerMessage.maxLength else { fail(Failure.protocolError("message too large")); return }
            guard available >= 4 + length else { break }
            let body = buffer.subdata(in: start + 4 ..< start + 4 + length)
            readOffset += 4 + length
            guard let message = PeerMessage.decode(body) else { fail(Failure.protocolError("malformed message")); return }
            onMessage?(message)
        }
        // Drop consumed bytes now and then rather than on every message.
        if readOffset > 0 && (readOffset == buffer.count || readOffset > 512 * 1024) {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + readOffset)
            buffer = Data(buffer)
            readOffset = 0
        }
    }
}
