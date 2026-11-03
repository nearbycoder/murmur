import Foundation
import Testing
@testable import MurmurKit

/// Two sessions on localhost: one seeds, the other downloads from a magnet link,
/// so metadata exchange, piece transfer, verification and storage are all exercised.
@Suite(.serialized)
struct SwarmTests {
    func makeSession(_ name: String, root: URL, encryption: EncryptionMode = .preferred, localDiscovery: Bool = false) -> Session {
        var config = Session.Configuration(downloadDirectory: root.appendingPathComponent("\(name)-downloads"), stateDirectory: root.appendingPathComponent("\(name)-state"))
        config.encryption = encryption
        config.enableDHT = false
        config.enablePortMapping = false
        config.enableLocalDiscovery = localDiscovery
        config.listenPort = UInt16.random(in: 40000...49000)
        return Session(configuration: config)
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    @Test func magnetDownloadFromLocalSeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-swarm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("seed-downloads/Album")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("Disc 2"), withIntermediateDirectories: true)
        var files: [String: Data] = [:]
        for (path, size) in [("01 Intro.flac", 1_300_000), ("Disc 2/02 Song.flac", 2_750_001), ("cover.jpg", 70_000)] {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            files[path] = data
            try data.write(to: content.appendingPathComponent(path))
        }
        var options = TorrentCreator.Options()
        options.pieceLength = 64 * 1024
        let torrentData = try TorrentCreator.create(from: content, options: options)

        let seed = makeSession("seed", root: root)
        seed.start()
        let id = try seed.addTorrent(data: torrentData)
        #expect(await waitUntil(20) { seed.statuses().first?.state == .seeding })

        let leech = makeSession("leech", root: root)
        leech.start()
        let magnet = MagnetLink(infoHash: id, displayName: nil, trackers: [], peers: [PeerAddress(host: "127.0.0.1", port: seed.port)])
        try leech.addMagnet(magnet)
        let finished = await waitUntil(60) { leech.statuses().first?.state == .seeding }
        #expect(finished, "state: \(String(describing: leech.statuses().first?.state)) progress: \(leech.statuses().first?.progress ?? -1)")

        let downloaded = root.appendingPathComponent("leech-downloads/Album")
        for (path, data) in files {
            #expect(try Data(contentsOf: downloaded.appendingPathComponent(path)) == data, "\(path) differs")
        }
        #expect(leech.statuses().first?.name == "Album")
        #expect(seed.statuses().first?.uploaded ?? 0 >= 4_000_000)

        // Skipping a file leaves it out; resume after restart keeps progress.
        await withCheckedContinuation { c in leech.shutdown { c.resume() } }
        await withCheckedContinuation { c in seed.shutdown { c.resume() } }
        let again = makeSession("leech", root: root)
        again.start()
        #expect(await waitUntil(10) { again.statuses().first?.state == .seeding })
        await withCheckedContinuation { c in again.shutdown { c.resume() } }
    }

    @Test(arguments: [EncryptionMode.required, .disabled]) func encryptionModes(_ mode: EncryptionMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-crypto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("seed-downloads/blob.bin")
        try FileManager.default.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: content)
        let torrentData = try TorrentCreator.create(from: content)
        // The seed accepts both kinds; the leech forces one.
        let seed = makeSession("seed", root: root, encryption: .preferred)
        seed.start()
        let id = try seed.addTorrent(data: torrentData)
        #expect(await waitUntil(20) { seed.statuses().first?.state == .seeding })
        let leech = makeSession("leech", root: root, encryption: mode)
        leech.start()
        try leech.addTorrent(data: torrentData)
        leech.addPeers(id, [PeerAddress(host: "127.0.0.1", port: seed.port)])
        #expect(await waitUntil(30) { leech.statuses().first?.state == .seeding })
        #expect(try Data(contentsOf: root.appendingPathComponent("leech-downloads/blob.bin")) == data)
        await withCheckedContinuation { c in leech.shutdown { c.resume() } }
        await withCheckedContinuation { c in seed.shutdown { c.resume() } }
    }

    @Test func findsPeersOnTheLocalNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-lsd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("seed-downloads/lan.bin")
        try FileManager.default.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: content)
        let torrentData = try TorrentCreator.create(from: content)
        let seed = makeSession("seed", root: root, localDiscovery: true)
        seed.start()
        try seed.addTorrent(data: torrentData)
        #expect(await waitUntil(20) { seed.statuses().first?.state == .seeding })
        // No trackers, no DHT, no peers given: only multicast discovery can connect them.
        let leech = makeSession("leech", root: root, localDiscovery: true)
        leech.start()
        try leech.addTorrent(data: torrentData)
        #expect(await waitUntil(30) { leech.statuses().first?.state == .seeding })
        await withCheckedContinuation { c in leech.shutdown { c.resume() } }
        await withCheckedContinuation { c in seed.shutdown { c.resume() } }
    }

    @Test func perTransferLimitAndExtraTrackers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("seed-downloads/slow.bin")
        try FileManager.default.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: content)
        let torrentData = try TorrentCreator.create(from: content)
        let seed = makeSession("seed", root: root)
        seed.start()
        let id = try seed.addTorrent(data: torrentData)
        #expect(await waitUntil(20) { seed.statuses().first?.state == .seeding })

        var config = Session.Configuration(downloadDirectory: root.appendingPathComponent("leech-downloads"), stateDirectory: root.appendingPathComponent("leech-state"))
        config.enableDHT = false
        config.enablePortMapping = false
        config.enableLocalDiscovery = false
        config.extraTrackers = ["udp://127.0.0.1:1/announce"]
        let leech = Session(configuration: config)
        leech.start()
        try leech.addTorrent(data: torrentData, paused: true)
        leech.setSpeedLimits([id], download: 400 * 1024, upload: nil)
        #expect(await waitUntil(5) { leech.statuses().first?.downloadLimit == 400 * 1024 })
        #expect(leech.details(for: id)?.trackers.map(\.url) == ["udp://127.0.0.1:1/announce"])
        let start = Date()
        leech.resume([id])
        leech.addPeers(id, [PeerAddress(host: "127.0.0.1", port: seed.port)])
        #expect(await waitUntil(40) { leech.statuses().first?.state == .seeding })
        #expect(Date().timeIntervalSince(start) > 3.5, "a 2 MB download at 400 KB/s can't finish this fast")
        await withCheckedContinuation { c in leech.shutdown { c.resume() } }
        await withCheckedContinuation { c in seed.shutdown { c.resume() } }
    }

    @Test func skippedFilesAreNotDownloaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("seed-downloads/Pack")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data((0..<600_000).map { _ in UInt8.random(in: 0...255) }).write(to: content.appendingPathComponent("a.bin"))
        try Data((0..<900_000).map { _ in UInt8.random(in: 0...255) }).write(to: content.appendingPathComponent("b.bin"))
        var options = TorrentCreator.Options()
        options.pieceLength = 32 * 1024
        let torrentData = try TorrentCreator.create(from: content, options: options)

        let seed = makeSession("seed", root: root)
        seed.start()
        let id = try seed.addTorrent(data: torrentData)
        #expect(await waitUntil(20) { seed.statuses().first?.state == .seeding })

        let leech = makeSession("leech", root: root)
        leech.start()
        try leech.addTorrent(data: torrentData, filePriorities: [.normal, .skip])
        leech.addPeers(id, [PeerAddress(host: "127.0.0.1", port: seed.port)])
        #expect(await waitUntil(30) { leech.statuses().first?.state == .seeding })
        let status = leech.statuses().first
        #expect(status?.wantedSize ?? 0 < 700_000)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("leech-downloads/Pack/a.bin").path))
        await withCheckedContinuation { c in leech.shutdown { c.resume() } }
        await withCheckedContinuation { c in seed.shutdown { c.resume() } }
    }
}

/// Downloads purely from an HTTP web seed (no peers at all), served by a local Python server.
@Suite(.serialized)
struct WebSeedTests {
    @Test func downloadsFromWebSeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-webseed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let served = root.appendingPathComponent("www")
        let content = served.appendingPathComponent("Pack")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let a = Data((0..<700_000).map { _ in UInt8.random(in: 0...255) }), b = Data((0..<333_333).map { _ in UInt8.random(in: 0...255) })
        try a.write(to: content.appendingPathComponent("a.bin"))
        try b.write(to: content.appendingPathComponent("sub/b b.bin"))
        let port = Int.random(in: 30000...39000)
        var options = TorrentCreator.Options()
        options.pieceLength = 64 * 1024
        options.webSeeds = ["http://127.0.0.1:\(port)/"]
        let torrent = try TorrentCreator.create(from: content, options: options)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", served.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .seconds(1))

        var config = Session.Configuration(downloadDirectory: root.appendingPathComponent("dl"), stateDirectory: root.appendingPathComponent("state"))
        config.enableDHT = false
        config.enableLocalDiscovery = false
        config.enablePortMapping = false
        config.listenPort = UInt16.random(in: 40000...49000)
        let session = Session(configuration: config)
        session.start()
        try session.addTorrent(data: torrent)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, session.statuses().first?.state != .seeding { try await Task.sleep(for: .milliseconds(200)) }
        #expect(session.statuses().first?.state == .seeding)
        #expect(try Data(contentsOf: root.appendingPathComponent("dl/Pack/a.bin")) == a)
        #expect(try Data(contentsOf: root.appendingPathComponent("dl/Pack/sub/b b.bin")) == b)
        await withCheckedContinuation { c in session.shutdown { c.resume() } }
    }
}
