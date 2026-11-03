import AppKit
import MurmurKit
import SwiftUI

/// Sample transfers for screenshots: `Murmur -demo YES [-demoScene overview|files|peers|trackers|empty]`.
/// It never starts the engine or touches the network, and keeps its settings apart from the real ones.
@MainActor
enum DemoMode {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var scene: String { UserDefaults.standard.string(forKey: "demoScene") ?? "overview" }

    private struct Item {
        let name: String
        let size: Int64
        let progress: Double
        let state: TorrentState
        let down: Double
        let up: Double
        let peers: Int
        let ext: String?
        let multi: Bool
        let files: Int
        let ratio: Double
    }

    private static let items: [Item] = [
        Item(name: "ubuntu-25.10-desktop-amd64.iso", size: 6_190_000_000, progress: 0.64, state: .downloading, down: 21_400_000, up: 1_350_000, peers: 58, ext: "iso", multi: false, files: 1, ratio: 0.08),
        Item(name: "Big Buck Bunny 4K", size: 10_620_000_000, progress: 0.31, state: .downloading, down: 9_800_000, up: 640_000, peers: 37, ext: nil, multi: true, files: 6, ratio: 0.02),
        Item(name: "Sintel (2010) Blender Open Movie", size: 1_420_000_000, progress: 1, state: .seeding, down: 0, up: 2_150_000, peers: 14, ext: nil, multi: true, files: 4, ratio: 3.41),
        Item(name: "debian-13.7.0-amd64-netinst.iso", size: 789_000_000, progress: 1, state: .seeding, down: 0, up: 420_000, peers: 6, ext: "iso", multi: false, files: 1, ratio: 1.87),
        Item(name: "Fedora-Workstation-Live-43.x86_64.iso", size: 2_480_000_000, progress: 0, state: .fetchingMetadata, down: 0, up: 0, peers: 3, ext: nil, multi: false, files: 0, ratio: 0),
        Item(name: "The Adventures of Sherlock Holmes (LibriVox)", size: 312_000_000, progress: 1, state: .finished, down: 0, up: 0, peers: 0, ext: nil, multi: true, files: 13, ratio: 2.0),
        Item(name: "archlinux-2026.11.01-x86_64.iso", size: 1_310_000_000, progress: 0.42, state: .paused, down: 0, up: 0, peers: 0, ext: "iso", multi: false, files: 1, ratio: 0.11),
        Item(name: "Tears of Steel 1080p", size: 3_720_000_000, progress: 0.71, state: .checking, down: 0, up: 0, peers: 0, ext: "mkv", multi: false, files: 1, ratio: 0.4),
    ]

    private static var timer: Timer?
    private static var tick = 0

    static func id(_ name: String) -> InfoHash { InfoHash.of(Data(name.utf8)) }

    static func start(store: TransferStore) {
        switch UserDefaults.standard.string(forKey: "demoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if scene == "empty" {
            store.apply([], SessionStats())
        } else {
            // Prime the speed graphs with a couple of minutes of history.
            for _ in 0..<120 { push(store) }
            store.selection = [id(items[0].name)]
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in if scene != "empty" { push(store) } }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            layOutWindow()
            switch scene {
            case "files": UserDefaults.standard.set(InspectorTab.files.rawValue, forKey: "inspectorTab")
            case "peers": UserDefaults.standard.set(InspectorTab.peers.rawValue, forKey: "inspectorTab")
            case "trackers": UserDefaults.standard.set(InspectorTab.trackers.rawValue, forKey: "inspectorTab")
            default: UserDefaults.standard.set(InspectorTab.overview.rawValue, forKey: "inspectorTab")
            }
            if scene == "files" { store.selection = [id(items[1].name)] }
            if scene == "noselect" { store.selection = [] }
            try? await Task.sleep(for: .seconds(0.6))
            if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
                print("DEMO_WINDOW \(window.windowNumber)")
                fflush(stdout)
                // Scripts that launch through `open` read the window number from a file instead.
                if let path = UserDefaults.standard.string(forKey: "demoWindowFile") {
                    try? "\(window.windowNumber)".write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private static func layOutWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let screen = window.screen ?? NSScreen.main else { return }
        let size = NSSize(width: 1240, height: 760)
        let frame = screen.visibleFrame
        window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func push(_ store: TransferStore) {
        tick += 1
        let t = Double(tick)
        var statuses: [TorrentStatus] = []
        for (index, item) in items.enumerated() {
            let wobble = 0.82 + 0.18 * sin(t / 5 + Double(index)) + 0.06 * sin(t / 1.7 + Double(index) * 2)
            let down = Int64(item.down * wobble)
            let up = Int64(item.up * (0.85 + 0.15 * cos(t / 4 + Double(index))))
            let completed = Int64(Double(item.size) * item.progress)
            statuses.append(TorrentStatus(
                id: id(item.name), name: item.name, state: item.state, progress: item.progress,
                totalSize: item.state == .fetchingMetadata ? 0 : item.size, wantedSize: item.state == .fetchingMetadata ? 0 : item.size,
                completedSize: item.state == .fetchingMetadata ? 0 : completed, downloadRate: down, uploadRate: up,
                downloaded: completed, uploaded: Int64(Double(item.size) * item.ratio), ratio: item.ratio,
                eta: down > 0 ? Double(item.size - completed) / Double(down) : nil,
                connectedPeers: item.peers, connectedSeeds: item.peers * 2 / 3, knownPeers: item.peers * 9,
                swarmSeeders: item.peers > 0 ? item.peers * 31 : nil, swarmLeechers: item.peers > 0 ? item.peers * 4 : nil,
                savePath: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                contentURL: nil, addedDate: Date().addingTimeInterval(-Double(index + 1) * 5400),
                completedDate: item.progress >= 1 ? Date().addingTimeInterval(-Double(index) * 3000) : nil,
                errorMessage: nil, checkingProgress: item.state == .checking ? 0.71 : nil, isPrivate: false,
                hasMetadata: item.state != .fetchingMetadata, fileCount: item.files, isSequential: false, queuePosition: index,
                magnetLink: "magnet:?xt=urn:btih:\(id(item.name).hex)", primaryFileExtension: item.multi ? nil : item.ext,
                isMultiFile: item.multi, ratioLimit: nil))
        }
        var stats = SessionStats()
        stats.downloadRate = statuses.reduce(0) { $0 + $1.downloadRate }
        stats.uploadRate = statuses.reduce(0) { $0 + $1.uploadRate }
        stats.connectedPeers = statuses.reduce(0) { $0 + $1.connectedPeers }
        stats.dhtNodes = 412
        stats.listenPort = 51413
        stats.portMapping = "NAT-PMP"
        stats.isListening = true
        stats.incomingConnections = 23
        store.apply(statuses, stats)
    }

    static func details(for id: InfoHash) -> TorrentDetails? {
        guard let index = items.firstIndex(where: { self.id($0.name) == id }) else { return nil }
        let item = items[index]
        var files: [FileStatus] = []
        if item.name.hasPrefix("Big Buck Bunny") {
            let list: [(String, Int64, Double, FilePriority)] = [
                ("bbb_sunflower_2160p_60fps_normal.mp4", 6_340_000_000, 0.38, .high),
                ("bbb_sunflower_1080p_60fps_normal.mp4", 3_560_000_000, 0.22, .normal),
                ("Extras/Making Of.mp4", 512_000_000, 0.4, .normal),
                ("Extras/Concept Art/poster.png", 8_400_000, 1, .normal),
                ("Extras/Concept Art/storyboard.pdf", 41_000_000, 0, .skip),
                ("README.txt", 2_100, 1, .normal),
            ]
            files = list.enumerated().map { FileStatus(id: $0.offset, path: $0.element.0, length: $0.element.1, downloaded: Int64(Double($0.element.1) * $0.element.2), priority: $0.element.3) }
        } else {
            files = [FileStatus(id: 0, path: item.name, length: item.size, downloaded: Int64(Double(item.size) * item.progress), priority: .normal)]
        }
        let clients = ["qBittorrent 5.1.2", "Transmission 4.06", "libtorrent 2.0.11", "Deluge 2.1.1", "µTorrent 3.6.0", "aria2 1.37.0", "BiglyBT 3.8.0", "Murmur 1.0.0", "rTorrent 0.15.1", "Tixati 3.33"]
        var generator = SeededGenerator(seed: UInt64(index + 7))
        let peers: [PeerStatus] = (0..<min(item.peers, 14)).map { i in
            let prefix = ["203.0.113", "198.51.100", "192.0.2"][i % 3]
            let progress = i % 3 == 0 ? 1 : Double.random(in: 0.05...0.97, using: &generator)
            let down = item.down > 0 && progress > 0.3 ? Int64(item.down / 9 * Double.random(in: 0.2...1.8, using: &generator)) : 0
            let up = item.up > 0 && progress < 1 ? Int64(item.up / 6 * Double.random(in: 0.1...1.5, using: &generator)) : 0
            return PeerStatus(address: PeerAddress(host: "\(prefix).\(Int.random(in: 2...250, using: &generator))", port: UInt16.random(in: 20000...65000, using: &generator)),
                              client: clients[(i + index) % clients.count], progress: progress, downloadRate: down, uploadRate: up,
                              downloaded: down * 90, uploaded: up * 90, isIncoming: i % 4 == 1, source: [.tracker, .dht, .pex, .incoming][i % 4],
                              flags: (down > 0 ? "D" : "d") + (up > 0 ? "U" : "") + (i % 4 == 1 ? "I" : "") + (i % 4 == 2 ? "X" : "") + (i % 4 == 1 ? "" : "H"))
        }.sorted { $0.downloadRate + $0.uploadRate > $1.downloadRate + $1.uploadRate }
        let trackers = [
            TrackerStatus(url: "udp://tracker.opentrackr.org:1337/announce", tier: 0, status: "Working", message: nil, seeders: item.peers * 31, leechers: item.peers * 4, peers: 80, lastAnnounce: Date().addingTimeInterval(-600), nextAnnounce: Date().addingTimeInterval(1200)),
            TrackerStatus(url: "https://torrent.ubuntu.com/announce", tier: 1, status: "Working", message: nil, seeders: item.peers * 22, leechers: item.peers * 3, peers: 50, lastAnnounce: Date().addingTimeInterval(-640), nextAnnounce: Date().addingTimeInterval(1160)),
            TrackerStatus(url: "udp://open.demonii.com:1337/announce", tier: 2, status: "Not working", message: "Timed out", seeders: nil, leechers: nil, peers: 0, lastAnnounce: nil, nextAnnounce: Date().addingTimeInterval(240)),
        ]
        let pieceCount = Int(item.size / (4 << 20))
        var mapGenerator = SeededGenerator(seed: 99)
        let map: [Float] = (0..<300).map { i in
            let x = Double(i) / 300
            if item.progress >= 1 { return 1 }
            let chance = item.progress * (1.2 - x * 0.4)
            return Double.random(in: 0...1, using: &mapGenerator) < chance ? 1 : (Double.random(in: 0...1, using: &mapGenerator) < 0.05 ? 0.5 : 0)
        }
        return TorrentDetails(id: id, files: files, peers: item.state == .downloading || item.state == .seeding ? peers : [], trackers: trackers,
                              pieceMap: map, pieceCount: pieceCount, pieceLength: 4 << 20,
                              comment: item.name.hasPrefix("ubuntu") ? "Ubuntu CD releases.ubuntu.com" : nil,
                              createdBy: "mktorrent 1.1", creationDate: Date().addingTimeInterval(-86400 * 20), webSeeds: [])
    }
}
