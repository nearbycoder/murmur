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

    // Protocol encryption (MSE/PE).
    private var mse: MSEHandshake?
    private var decryptor: RC4?
    private var encryptor: RC4?
    private var pendingWrites: [Data] = []
    private var classifiedIncoming = false
    /// For incoming connections: finds the torrent for an MSE `req2` hash, and the session's policy.
    var incomingLookup: ((Data) -> InfoHash?)?
    var incomingMode: EncryptionMode = .preferred
    /// True when this connection tried (or is using) the encrypted handshake.
    private(set) var attemptedEncryption = false
    /// True once traffic is RC4-encrypted.
    private(set) var isEncrypted = false

    /// Return false to drop the connection (wrong torrent, ourselves, banned).
    var onHandshake: ((Handshake) -> Bool)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClose: ((Error?) -> Void)?
    var onConnected: (() -> Void)?
    /// Called after queued data has gone out, so uploads can keep the pipe full.
    var onDrain: (() -> Void)?

    /// Session-wide and per-torrent limits; reading waits for the slowest.
    var downloadLimiters: [RateLimiter] = []
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

    /// Makes an outgoing connection open with the encrypted handshake. Call before `start()`.
    func useEncryption(infoHash: InfoHash, allowPlaintext: Bool) {
        mse = MSEHandshake(role: .initiator(infoHash: infoHash, allowPlaintext: allowPlaintext))
        attemptedEncryption = true
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !isConnected else { return }
                isConnected = true
                if let mse {
                    mse.start()
                    rawWrite(mse.takeOutput())
                }
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
        // Peer wire messages wait until the encrypted handshake is done.
        if mse != nil {
            pendingWrites.append(data)
            return
        }
        if encryptor != nil {
            rawWrite(encryptor!.process(data))
        } else {
            rawWrite(data)
        }
    }

    private func rawWrite(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
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
                receivedRaw(data)
                if closed { return }
                let wait = downloadLimiters.map { $0.consume(data.count) }.max() ?? 0
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

    private func receivedRaw(_ raw: Data) {
        var data = raw
        if !isIncoming || classifiedIncoming {
            if decryptor != nil { data = decryptor!.process(data) }
        } else {
            // An incoming connection is plaintext if it opens with the BitTorrent header, encrypted otherwise.
            buffer.append(data)
            guard buffer.count - readOffset >= 20 else { return }
            classifiedIncoming = true
            let head = buffer.subdata(in: buffer.startIndex + readOffset ..< buffer.startIndex + readOffset + 20)
            data = Data(buffer.dropFirst(readOffset))
            buffer = Data()
            readOffset = 0
            if head.first == 19 && head.dropFirst() == Handshake.protocolName {
                guard incomingMode != .required else { fail(Failure.protocolError("plaintext not allowed")); return }
            } else {
                guard let lookup = incomingLookup else { fail(Failure.protocolError("encryption unavailable")); return }
                mse = MSEHandshake(role: .responder(lookup: lookup, allowPlaintext: incomingMode != .required))
                attemptedEncryption = true
                mse!.start()
            }
        }
        if let handshake = mse {
            let result = handshake.feed(data)
            rawWrite(handshake.takeOutput())
            switch result {
            case .needMore:
                return
            case .failed:
                fail(Failure.protocolError("encryption handshake failed"))
                return
            case .done(let incoming, let outgoing, let payload, _):
                mse = nil
                decryptor = incoming
                encryptor = outgoing
                isEncrypted = incoming != nil
                let queued = pendingWrites
                pendingWrites = []
                for item in queued { write(item) }
                data = payload
            }
        }
        buffer.append(data)
        process()
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
