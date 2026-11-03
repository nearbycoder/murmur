import AppKit
import IOKit.pwr_mgt
import MurmurKit
import UniformTypeIdentifiers
import UserNotifications

/// The Dock icon: a badge with the number of downloads and an overall progress bar.
@MainActor
final class DockController {
    static let shared = DockController()
    private let progressView = DockProgressView()
    private var lastBadge: String?
    private var lastProgress: Double?

    func update(transfers: [TorrentStatus], stats: SessionStats, settings: AppSettings) {
        let downloading = transfers.filter { $0.state == .downloading || $0.state == .fetchingMetadata }
        let badge = settings.showDockBadge && !downloading.isEmpty ? "\(downloading.count)" : nil
        if badge != lastBadge {
            NSApp.dockTile.badgeLabel = badge
            lastBadge = badge
        }
        let wanted = downloading.reduce(Int64(0)) { $0 + $1.wantedSize }
        let done = downloading.reduce(Int64(0)) { $0 + $1.completedSize }
        let progress: Double? = wanted > 0 ? Double(done) / Double(wanted) : nil
        guard progress.map({ Int($0 * 200) }) != lastProgress.map({ Int($0 * 200) }) else { return }
        lastProgress = progress
        progressView.progress = progress
        NSApp.dockTile.contentView = progress == nil ? nil : progressView
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var progress: Double?

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let inset = bounds.width * 0.14
        let height = bounds.height * 0.1
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        let inner = track.insetBy(dx: height * 0.18, dy: height * 0.18)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * progress), height: inner.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

/// Keeps the Mac awake while something is downloading.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func update(active: Bool) {
        if active && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Murmur is downloading" as CFString, &assertion) == kIOReturnSuccess
        } else if !active && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

/// Completion notifications, with a button to show the download in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        let reveal = UNNotificationAction(identifier: "reveal", title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: "finished", actions: [reveal], intentIdentifiers: [])])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyFinished(name: String, url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = name
        content.sound = .default
        content.categoryIdentifier = "finished"
        if let url { content.userInfo = ["path": url.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notifyFailed(name: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transfer Stopped"
        content.body = "\(name): \(message)"
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            if let path, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                NSApp.activate()
                TransferStore.shared.openMainWindow?()
            }
        }
    }
}

/// Adds .torrent files that appear in a chosen folder, then renames them so they're added once.
@MainActor
final class WatchFolder {
    static let shared = WatchFolder()
    private var timer: Timer?
    private weak var store: TransferStore?

    func start(store: TransferStore) {
        self.store = store
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    private func scan() {
        guard let store, store.settings.watchFolderEnabled, let folder = store.settings.watchFolder else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "torrent" {
            guard let data = try? Data(contentsOf: url), (try? Metainfo(data: data)) != nil else { continue }
            store.addTorrent(data: data, ask: false)
            let added = url.appendingPathExtension("added")
            try? FileManager.default.moveItem(at: url, to: added)
        }
    }
}

/// Registers Murmur as the handler for magnet links and .torrent files.
enum DefaultApp {
    static let torrentType = UTType(importedAs: "org.bittorrent.torrent")

    static var isDefault: Bool {
        guard let magnet = URL(string: "magnet:?xt=urn:btih:0"), let handler = NSWorkspace.shared.urlForApplication(toOpen: magnet) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefault() async {
        let app = Bundle.main.bundleURL
        try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet")
        try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: torrentType)
    }
}
