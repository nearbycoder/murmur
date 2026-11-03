// A headless client for trying the engine against real swarms.
//   murmur-cli <magnet | file.torrent> [--dir <folder>] [--seconds <n>] [--seed] [--peer <ip:port>] [--encryption disabled|preferred|required]
//   murmur-cli create <file or folder> <out.torrent>
import Foundation
import MurmurKit

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "create", arguments.count >= 3 {
    let data = try TorrentCreator.create(from: URL(fileURLWithPath: arguments[1]))
    try data.write(to: URL(fileURLWithPath: arguments[2]))
    print("wrote \(arguments[2]) (\(try Metainfo(data: data).info.infoHash))")
    exit(0)
}
guard let source = arguments.first else {
    print("usage: murmur-cli <magnet | file.torrent> [--dir <folder>] [--seconds <n>] [--seed]")
    exit(1)
}
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let directory = URL(fileURLWithPath: option("--dir") ?? FileManager.default.currentDirectoryPath)
let seconds = option("--seconds").flatMap(Double.init) ?? .infinity
let keepSeeding = arguments.contains("--seed")

let state = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-cli-state")
var config = Session.Configuration(downloadDirectory: directory, stateDirectory: state)
config.maxActiveDownloads = 0
if let mode = option("--encryption").flatMap(EncryptionMode.init(rawValue:)) { config.encryption = mode }
let session = Session(configuration: config)
session.onEvent = { event in print("event: \(event)") }
nonisolated(unsafe) var lastStats = SessionStats()
session.onUpdate = { _, stats in lastStats = stats }
session.start()

do {
    if source.hasPrefix("magnet:") {
        try session.addMagnet(MagnetLink(source))
    } else {
        try session.addTorrent(data: Data(contentsOf: URL(fileURLWithPath: source)))
    }
} catch {
    print("error: \(error.localizedDescription)")
}
if let peer = option("--peer").flatMap(PeerAddress.init(string:)), let id = session.statuses().first?.id {
    session.addPeers(id, [peer])
}

let start = Date()
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 2)
        let elapsed = Date().timeIntervalSince(start)
        print("  dht nodes \(lastStats.dhtNodes), port \(lastStats.listenPort) listening \(lastStats.isListening), mapping \(lastStats.portMapping ?? "none"), incoming \(lastStats.incomingConnections)")
        for s in session.statuses() {
            let details = session.details(for: s.id)
            let trackers = details?.trackers.map { "\($0.status.prefix(4))" }.joined(separator: ",") ?? ""
            print(String(format: "[%4.0fs] %@ %@ %5.1f%% ↓%@/s ↑%@/s peers %d (seeds %d) known %d trackers %@",
                         elapsed, s.state.rawValue, String(s.name.prefix(30)), s.progress * 100,
                         formatBytes(s.downloadRate), formatBytes(s.uploadRate), s.connectedPeers, s.connectedSeeds, s.knownPeers, trackers))
            if let error = s.errorMessage { print("  error: \(error)") }
            for seed in details?.webSeedStatuses ?? [] {
                print("  web seed \(seed.url): \(seed.status) \(formatBytes(seed.downloaded)) at \(formatBytes(seed.downloadRate))/s \(seed.message ?? "")")
            }
            if s.state == .seeding && !keepSeeding {
                print("done in \(Int(elapsed))s")
                exit(0)
            }
        }
        if elapsed > seconds {
            session.shutdown { exit(0) }
            return
        }
    }
}
dispatchMain()
