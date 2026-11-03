import Foundation
import Testing
@testable import MurmurKit

struct BencodeTests {
    @Test func decodesScalarsAndContainers() throws {
        let value = try BencodeDecoder.decode(Data("d3:bar4:spam3:fooi42e4:listli-3e1:xee".utf8))
        #expect(value["bar"]?.string == "spam")
        #expect(value["foo"]?.int == 42)
        #expect(value["list"]?.list == [.integer(-3), BencodeValue("x")])
    }

    @Test func roundTripsWithSortedKeys() throws {
        let value = BencodeValue.dictionary(["zeta": .integer(1), "alpha": .list([BencodeValue("a"), .integer(0)])])
        let encoded = value.encoded()
        #expect(String(decoding: encoded, as: UTF8.self) == "d5:alphal1:ai0ee4:zetai1ee")
        #expect(try BencodeDecoder.decode(encoded) == value)
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("i12".utf8)) }
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("5:abc".utf8)) }
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("ie".utf8)) }
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("i1ei2e".utf8)) }
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data(String(repeating: "l", count: 100).utf8)) }
    }

    @Test func recordsInfoRange() throws {
        let raw = Data("d8:announce3:url4:infod4:name1:xee".utf8)
        var decoder = BencodeDecoder(raw)
        _ = try decoder.decodeValue()
        #expect(decoder.infoBytes() == Data("d4:name1:xe".utf8))
    }

    @Test func decodesPrefixWithTrailingBytes() throws {
        let (value, used) = try BencodeDecoder.decodePrefix(Data("d8:msg_typei1eeRAW".utf8))
        #expect(value["msg_type"]?.int == 1)
        #expect(used == 15)
    }
}

struct MagnetTests {
    @Test func parsesHexMagnet() throws {
        let link = try MagnetLink("magnet:?xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&dn=Some+Name&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce&tr=http://t.example/announce&x.pe=10.0.0.1:6881")
        #expect(link.infoHash.hex == "c12fe1c06bba254a9dc9f519b335aa7c1367a88a")
        #expect(link.displayName == "Some Name")
        #expect(link.trackers == ["udp://tracker.example:1337/announce", "http://t.example/announce"])
        #expect(link.peers == [PeerAddress(host: "10.0.0.1", port: 6881)])
    }

    @Test func parsesBase32Magnet() throws {
        let link = try MagnetLink("magnet:?xt=urn:btih:YEX6DQDLXISUVHOJ6UM3GNNKPQJWPKEK")
        #expect(link.infoHash.hex == "c12fe1c06bba254a9dc9f519b335aa7c1367a88a")
    }

    @Test func roundTripsURI() throws {
        let link = try MagnetLink("magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=A%20%26%20B&tr=udp%3A%2F%2Fx%3A1%2Fa")
        let again = try MagnetLink(link.uri)
        #expect(again == link)
        #expect(again.displayName == "A & B")
    }

    @Test func rejectsNonMagnets() {
        #expect(throws: MagnetError.self) { try MagnetLink("https://example.com") }
        #expect(throws: MagnetError.self) { try MagnetLink("magnet:?dn=nothing") }
    }

    @Test func findsMagnetInText() {
        let text = "Grab it here: magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=x thanks"
        #expect(MagnetLink.find(in: text)?.infoHash.hex == "c12fe1c06bba254a9dc9f519b335aa7c1367a88a")
        #expect(MagnetLink.find(in: "nothing here") == nil)
    }
}

struct MetainfoTests {
    func makeInfo(files: [[String: BencodeValue]]? = nil, length: Int64 = 40_000, pieceLength: Int64 = 16_384, name: String = "demo") -> Data {
        let total = files.map { $0.reduce(0) { $0 + ($1["length"]?.int ?? 0) } } ?? length
        let count = Int((total + pieceLength - 1) / pieceLength)
        var info: [String: BencodeValue] = ["name": BencodeValue(name), "piece length": .integer(pieceLength), "pieces": .bytes(Data(count: 20 * count))]
        if let files { info["files"] = .list(files.map { .dictionary($0) }) } else { info["length"] = .integer(length) }
        return BencodeValue.dictionary(info).encoded()
    }

    @Test func parsesSingleFile() throws {
        let info = try TorrentInfo(rawInfo: makeInfo())
        #expect(info.name == "demo")
        #expect(info.pieceCount == 3)
        #expect(info.pieceSize(2) == 40_000 - 2 * 16_384)
        #expect(!info.isMultiFile)
    }

    @Test func sanitizesHostilePaths() throws {
        let files: [[String: BencodeValue]] = [
            ["length": .integer(10), "path": .list([BencodeValue(".."), BencodeValue(".."), BencodeValue("etc"), BencodeValue("passwd")])],
            ["length": .integer(10), "path": .list([BencodeValue("/abs"), BencodeValue("a:b")])],
            ["length": .integer(10), "path": .list([BencodeValue("etc"), BencodeValue("passwd")])],
        ]
        let info = try TorrentInfo(rawInfo: makeInfo(files: files, name: "../evil"))
        #expect(info.name == ".._evil")
        #expect(info.files[0].path == ["etc", "passwd"])
        #expect(info.files[1].path == ["_abs", "a_b"])
        // A path that collides after sanitizing gets renamed instead of overwriting.
        #expect(info.files[2].path != info.files[0].path)
        for file in info.files { #expect(!file.path.contains("..")) }
    }

    @Test func roundTripsTorrentFile() throws {
        let raw = makeInfo()
        let meta = Metainfo(info: try TorrentInfo(rawInfo: raw), trackers: [["udp://a:1"], ["http://b/announce"]], comment: "hi")
        let parsed = try Metainfo(data: meta.encoded())
        #expect(parsed.info.infoHash == meta.info.infoHash)
        #expect(parsed.trackers == [["udp://a:1"], ["http://b/announce"]])
        #expect(parsed.comment == "hi")
    }

    @Test func createsTorrentFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 1234).write(to: dir.appendingPathComponent("sub/b.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = TorrentCreator.Options()
        options.trackers = [["udp://tracker.example:80"]]
        options.pieceLength = 16384
        let meta = try Metainfo(data: try TorrentCreator.create(from: dir, options: options))
        #expect(meta.info.files.map(\.relativePath) == ["a.bin", "sub/b.txt"])
        #expect(meta.info.totalLength == 51_234)
        #expect(meta.info.pieceCount == 4)
        #expect(meta.trackers == [["udp://tracker.example:80"]])
    }
}

struct WireTests {
    @Test func bitfieldRoundTrip() {
        var bits = Bitfield(count: 10)
        bits[0] = true; bits[9] = true; bits[9] = true
        #expect(bits.cardinality == 2)
        #expect(bits.data == Data([0x80, 0x40]))
        #expect(Bitfield(data: Data([0x80, 0x40]), count: 10) == bits)
        // Spare bits must be clear.
        #expect(Bitfield(data: Data([0x80, 0x41]), count: 10) == nil)
        #expect(Bitfield(count: 10, filled: true).isFull)
    }

    @Test func messageRoundTrip() {
        let messages: [PeerMessage] = [.choke, .have(7), .request(BlockRequest(piece: 3, begin: 16384, length: 16384)), .piece(index: 1, begin: 0, block: Data([1, 2, 3])), .port(6881), .extended(id: 2, payload: Data("de".utf8))]
        for message in messages {
            let encoded = message.encoded()
            let length = Int(encoded.uint32(at: 0))
            #expect(length == encoded.count - 4)
            let decoded = PeerMessage.decode(encoded.dropFirst(4))
            #expect(decoded.map { "\($0)" } == "\(message)")
        }
    }

    @Test func compactPeers() {
        let data = Data([10, 0, 0, 1, 0x1A, 0xE1, 0, 0, 0, 0, 0, 1])
        #expect(PeerAddress.parseCompact(data) == [PeerAddress(host: "10.0.0.1", port: 6881)])
        #expect(PeerAddress(host: "10.0.0.1", port: 6881).compact == data.prefix(6))
    }

    @Test func clientNames() {
        #expect(PeerIdentity.clientName(for: Data("-qB4630-abcdefghijkl".utf8)) == "qBittorrent 4.6.3")
        #expect(PeerIdentity.clientName(for: Data("-TR4060-abcdefghijkl".utf8)) == "Transmission 4.06")
        #expect(PeerIdentity.clientName(for: PeerIdentity.generate())?.hasPrefix("Murmur") == true)
    }

    @Test func storageSegmentsSpanFiles() throws {
        let files: [[String: BencodeValue]] = [
            ["length": .integer(10_000), "path": .list([BencodeValue("a")])],
            ["length": .integer(0), "path": .list([BencodeValue("empty")])],
            ["length": .integer(20_000), "path": .list([BencodeValue("b")])],
        ]
        let info = try TorrentInfo(rawInfo: MetainfoTests().makeInfo(files: files))
        let storage = Storage(info: info, root: URL(fileURLWithPath: "/tmp"))
        let segments = storage.pieceSegments(0)
        #expect(segments.map(\.file) == [0, 2])
        #expect(segments.map(\.length) == [10_000, 6384])
        #expect(segments[1].offset == 0)
        #expect(segments[1].position == 10_000)
        #expect(storage.pieceSegments(1).first?.offset == 6384)
    }
}
