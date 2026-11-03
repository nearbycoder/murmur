import Foundation
import Testing
@testable import MurmurKit

/// Two sessions on localhost: one seeds, the other downloads from a magnet link,
/// so metadata exchange, piece transfer, verification and storage are all exercised.
@Suite(.serialized)
struct SwarmTests {
    func makeSession(_ name: String, root: URL) -> Session {
        var config = Session.Configuration(downloadDirectory: root.appendingPathComponent("\(name)-downloads"), stateDirectory: root.appendingPathComponent("\(name)-state"))
        config.enableDHT = false
        config.enablePortMapping = false
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
