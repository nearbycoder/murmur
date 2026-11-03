import Foundation
import Testing
@testable import MurmurKit

struct EncryptionTests {
    @Test func rc4KnownAnswer() {
        var rc4 = RC4(key: Data("Key".utf8))
        #expect(rc4.process(Data("Plaintext".utf8)).hexString == "bbf316e8d940af0ad3")
    }

    @Test func diffieHellmanMatchesReference() {
        let math = Montgomery(modulus: MSEHandshake.prime)
        let x = Data(hex: "0123456789abcdef0123456789abcdef01234567")!
        #expect(math.power(Data([2]), x).hexString == "6fd4bc7aa649593205ec30348a3ccc737b61fa01e9e1762c2c53eb69033afecbdf7c13b8ac3643af78d0760b0f42db009f2b96c970f009d060faf617f117d0f1c221cea0561b9a86e852fc70a6f09ad0f82378603aa5e56b811deb3f534bf276")
        // Both sides of an exchange agree on the secret.
        let a = Data((0..<20).map { _ in UInt8.random(in: 0...255) }), b = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let ya = math.power(Data([2]), a), yb = math.power(Data([2]), b)
        #expect(math.power(yb, a) == math.power(ya, b))
    }

    /// Runs both ends of the handshake against each other in memory, in awkward chunk sizes.
    @Test(arguments: [true, false]) func handshakeNegotiates(allowPlaintext: Bool) {
        let hash = InfoHash.of(Data("demo".utf8))
        let initiator = MSEHandshake(role: .initiator(infoHash: hash, allowPlaintext: allowPlaintext))
        let responder = MSEHandshake(role: .responder(lookup: { req2 in (Data("req2".utf8) + hash.bytes).sha1() == req2 ? hash : nil }, allowPlaintext: true))
        initiator.start()
        responder.start()
        var toResponder = initiator.takeOutput() + Data("hello responder".utf8)
        var toInitiator = Data()
        var initiatorDone: (RC4?, RC4?)?
        var responderDone: (RC4?, RC4?, Data)?
        for _ in 0..<20 where initiatorDone == nil || responderDone == nil {
            if responderDone == nil, !toResponder.isEmpty {
                let chunk = toResponder.prefix(37); toResponder = Data(toResponder.dropFirst(37))
                if case .done(let i, let o, let payload, let found) = responder.feed(chunk) {
                    #expect(found == hash)
                    responderDone = (i, o, payload)
                }
                toInitiator += responder.takeOutput()
            }
            if initiatorDone == nil, !toInitiator.isEmpty {
                if case .done(let i, let o, _, _) = initiator.feed(toInitiator) { initiatorDone = (i, o) }
                toInitiator = Data()
                toResponder += initiator.takeOutput()
            }
        }
        #expect(initiatorDone != nil)
        #expect(responderDone != nil)
        // The responder prefers RC4, so traffic is encrypted either way and both ciphers line up.
        guard var send = initiatorDone?.1, var receive = responderDone?.0 else { return }
        let message = Data("BitTorrent payload".utf8)
        #expect(receive.process(send.process(message)) == message)
    }
}
