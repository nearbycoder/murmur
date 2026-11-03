import Foundation

/// How a session treats BitTorrent protocol encryption (MSE/PE).
public enum EncryptionMode: String, Codable, Sendable, CaseIterable {
    /// Plaintext outgoing connections; encrypted incoming ones are still accepted.
    case disabled
    /// Try encryption first and fall back to plaintext; accept both.
    case preferred
    /// Only encrypted connections, both ways.
    case required
}

/// The Message Stream Encryption handshake. It runs on raw socket bytes before the peer wire
/// protocol starts, then hands over RC4 ciphers (or none, when plaintext was negotiated).
final class MSEHandshake {
    enum Role {
        case initiator(infoHash: InfoHash, allowPlaintext: Bool)
        case responder(lookup: (Data) -> InfoHash?, allowPlaintext: Bool)
    }

    enum Result {
        case needMore
        case failed
        /// Done: ciphers to use from now on (nil for plaintext), and payload bytes already decrypted.
        case done(incoming: RC4?, outgoing: RC4?, payload: Data, infoHash: InfoHash)
    }

    static let prime = Data(hex: "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563")!
    private static let math = Montgomery(modulus: prime)
    private static let vc = Data(count: 8)
    private static let cryptoPlaintext: UInt32 = 0x01
    private static let cryptoRC4: UInt32 = 0x02

    private let role: Role
    private let privateKey = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    private var buffer = Data()
    private var state = State.start
    private var secret = Data()
    private var skey: InfoHash?
    private var incoming: RC4?
    private var outgoing: RC4?
    private var syncPattern = Data()
    private var padLength = 0
    private var provided: UInt32 = 0
    /// Bytes to send to the peer, collected while processing.
    private(set) var output = Data()

    private enum State {
        case start, waitPublicKey, syncVC, waitSelect, waitPadD
        case syncReq1, waitReq23, waitProvide, waitPadC, waitIA
    }

    init(role: Role) {
        self.role = role
    }

    func takeOutput() -> Data {
        defer { output = Data() }
        return output
    }

    private var publicKey: Data { MSEHandshake.math.power(Data([2]), privateKey) }

    private func padding() -> Data { Data((0..<Int.random(in: 0...64)).map { _ in UInt8.random(in: 0...255) }) }

    private static func hash(_ parts: Data...) -> Data { parts.reduce(Data(), +).sha1() }

    /// The initiator speaks first.
    func start() {
        guard case .initiator = role else { state = .waitPublicKey; return }
        output.append(publicKey)
        output.append(padding())
        state = .waitPublicKey
    }

    func feed(_ data: Data) -> Result {
        buffer.append(data)
        while true {
            let step = advance()
            switch step {
            case .continue: continue
            case .result(let result): return result
            }
        }
    }

    private enum Step { case `continue`, result(Result) }

    private func consume(_ count: Int) -> Data {
        let chunk = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(chunk)
    }

    private func advance() -> Step {
        switch state {
        case .start:
            return .result(.failed)

        case .waitPublicKey:
            guard buffer.count >= 96 else { return .result(.needMore) }
            let theirs = consume(96)
            secret = MSEHandshake.math.power(theirs, privateKey)
            switch role {
            case .initiator(let infoHash, let allowPlaintext):
                skey = infoHash
                output.append(MSEHandshake.hash(Data("req1".utf8), secret))
                let req2 = MSEHandshake.hash(Data("req2".utf8), infoHash.bytes)
                let req3 = MSEHandshake.hash(Data("req3".utf8), secret)
                output.append(Data(zip(req2, req3).map { $0 ^ $1 }))
                var out = RC4(key: MSEHandshake.hash(Data("keyA".utf8), secret, infoHash.bytes), discard: 1024)
                let inc = RC4(key: MSEHandshake.hash(Data("keyB".utf8), secret, infoHash.bytes), discard: 1024)
                var body = MSEHandshake.vc
                body.appendUInt32(allowPlaintext ? MSEHandshake.cryptoRC4 | MSEHandshake.cryptoPlaintext : MSEHandshake.cryptoRC4)
                body.appendUInt16(0) // no PadC
                body.appendUInt16(0) // no initial payload; the BT handshake follows once this is done
                output.append(out.process(body))
                // The peer's reply starts with an encrypted VC somewhere after its padding.
                var probe = inc
                syncPattern = probe.process(MSEHandshake.vc)
                outgoing = out
                incoming = inc
                state = .syncVC
            case .responder:
                output.append(publicKey)
                output.append(padding())
                syncPattern = MSEHandshake.hash(Data("req1".utf8), secret)
                state = .syncReq1
            }
            return .continue

        case .syncVC:
            guard let range = buffer.range(of: syncPattern) else {
                return .result(buffer.count > 512 + 8 ? .failed : .needMore)
            }
            _ = consume(range.lowerBound - buffer.startIndex)
            _ = incoming!.process(consume(8))
            state = .waitSelect
            return .continue

        case .waitSelect:
            guard buffer.count >= 6 else { return .result(.needMore) }
            let fields = incoming!.process(consume(6))
            provided = fields.uint32(at: 0)
            padLength = Int(fields.uint16(at: 4))
            guard padLength <= 512 else { return .result(.failed) }
            state = .waitPadD
            return .continue

        case .waitPadD:
            guard buffer.count >= padLength else { return .result(.needMore) }
            _ = incoming!.process(consume(padLength))
            guard case .initiator(let infoHash, let allowPlaintext) = role else { return .result(.failed) }
            if provided == MSEHandshake.cryptoRC4 {
                let rest = incoming!.process(consume(buffer.count))
                return .result(.done(incoming: incoming, outgoing: outgoing, payload: rest, infoHash: infoHash))
            } else if provided == MSEHandshake.cryptoPlaintext && allowPlaintext {
                return .result(.done(incoming: nil, outgoing: nil, payload: consume(buffer.count), infoHash: infoHash))
            }
            return .result(.failed)

        case .syncReq1:
            guard let range = buffer.range(of: syncPattern) else {
                return .result(buffer.count > 512 + 20 ? .failed : .needMore)
            }
            _ = consume(range.upperBound - buffer.startIndex)
            state = .waitReq23
            return .continue

        case .waitReq23:
            guard buffer.count >= 20, case .responder(let lookup, _) = role else { return .result(.needMore) }
            let mixed = consume(20)
            let req3 = MSEHandshake.hash(Data("req3".utf8), secret)
            let req2 = Data(zip(mixed, req3).map { $0 ^ $1 })
            guard let infoHash = lookup(req2) else { return .result(.failed) }
            skey = infoHash
            incoming = RC4(key: MSEHandshake.hash(Data("keyA".utf8), secret, infoHash.bytes), discard: 1024)
            outgoing = RC4(key: MSEHandshake.hash(Data("keyB".utf8), secret, infoHash.bytes), discard: 1024)
            state = .waitProvide
            return .continue

        case .waitProvide:
            guard buffer.count >= 14 else { return .result(.needMore) }
            let fields = incoming!.process(consume(14))
            guard fields.prefix(8) == MSEHandshake.vc else { return .result(.failed) }
            provided = fields.uint32(at: 8)
            padLength = Int(fields.uint16(at: 12))
            guard padLength <= 512 else { return .result(.failed) }
            state = .waitPadC
            return .continue

        case .waitPadC:
            guard buffer.count >= padLength + 2 else { return .result(.needMore) }
            _ = incoming!.process(consume(padLength))
            padLength = Int(incoming!.process(consume(2)).uint16(at: 0)) // length of the initial payload
            state = .waitIA
            return .continue

        case .waitIA:
            guard buffer.count >= padLength, case .responder(_, let allowPlaintext) = role, let skey else { return .result(.needMore) }
            let initial = incoming!.process(consume(padLength))
            let select: UInt32
            if provided & MSEHandshake.cryptoRC4 != 0 {
                select = MSEHandshake.cryptoRC4
            } else if provided & MSEHandshake.cryptoPlaintext != 0 && allowPlaintext {
                select = MSEHandshake.cryptoPlaintext
            } else {
                return .result(.failed)
            }
            var reply = MSEHandshake.vc
            reply.appendUInt32(select)
            reply.appendUInt16(0)
            output.append(outgoing!.process(reply))
            if select == MSEHandshake.cryptoRC4 {
                let rest = incoming!.process(consume(buffer.count))
                return .result(.done(incoming: incoming, outgoing: outgoing, payload: initial + rest, infoHash: skey))
            }
            return .result(.done(incoming: nil, outgoing: nil, payload: initial + consume(buffer.count), infoHash: skey))
        }
    }
}
