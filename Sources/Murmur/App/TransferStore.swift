import AppKit
import MurmurKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum TransferFilter: String, CaseIterable, Identifiable {
    case all, downloading, seeding, completed, paused, errors
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Transfers"
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .completed: "Completed"
        case .paused: "Paused"
        case .errors: "Errors"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        case .errors: "exclamationmark.triangle"
        }
    }

    func matches(_ t: TorrentStatus) -> Bool {
        switch self {
        case .all: true
        case .downloading: [.downloading, .fetchingMetadata, .checking].contains(t.state) || (t.state == .queued && !t.isComplete)
        case .seeding: t.state == .seeding
        case .completed: t.isComplete && t.state != .error
        case .paused: t.state == .paused
        case .errors: t.state == .error
        }
    }
}

enum TransferSort: String, CaseIterable, Identifiable {
    case queue, name, dateAdded, size, progress, downloadSpeed, uploadSpeed, ratio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "Queue Order"
        case .name: "Name"
        case .dateAdded: "Date Added"
        case .size: "Size"
        case .progress: "Progress"
        case .downloadSpeed: "Download Speed"
        case .uploadSpeed: "Upload Speed"
        case .ratio: "Ratio"
        }
    }
}

struct SpeedSample: Identifiable, Equatable {
    let id: Int
    let down: Double
    let up: Double
}

/// A .torrent file waiting for the user to pick files and a location.
struct PendingTorrent: Identifiable {
    let id = UUID()
    let data: Data
    let meta: Metainfo
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The app's view of the engine: transfer snapshots, selection, filters and actions.
@MainActor
@Observable
final class TransferStore {
    static let shared = TransferStore()

    let settings = AppSettings.shared
    private(set) var session: Session?

    private(set) var transfers: [TorrentStatus] = []
    private(set) var stats = SessionStats()
    var selection: Set<InfoHash> = [] {
        didSet { if selection != oldValue { details = nil; refreshDetails() } }
    }
    var filter: TransferFilter = .all
    var searchText = ""
    var inspectorVisible = true
    private(set) var details: TorrentDetails?
    private(set) var speedHistory: [SpeedSample] = []
    private(set) var transferHistory: [InfoHash: [SpeedSample]] = [:]
    private var tick = 0

    var pendingTorrents: [PendingTorrent] = []
    var showMagnetSheet = false
    var showCreateSheet = false
    var magnetDraft = ""
    var alert: AlertItem?
    var removeRequest: [InfoHash]?
    /// A magnet link spotted on the clipboard when Murmur became active.
    var clipboardMagnet: MagnetLink?
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var lastSessionDownloaded: Int64 = 0
    private var lastSessionUploaded: Int64 = 0
    private var scheduleWasActive: Bool?
    let launchDate = Date()

    private init() {}

    // MARK: - Engine

    func start() {
        guard session == nil else { return }
        if DemoMode.isEnabled {
            DemoMode.start(store: self)
            return
        }
        try? FileManager.default.createDirectory(at: AppSettings.stateDirectory, withIntermediateDirectories: true)
        let session = Session(configuration: settings.engineConfiguration)
        session.onUpdate = { [weak self] statuses, stats in self?.apply(statuses, stats) }
        session.onEvent = { [weak self] event in self?.handle(event) }
        settings.onEngineChange = { [weak self] in
            guard let self, let session = self.session else { return }
            session.update(configuration: settings.engineConfiguration)
        }
        session.start()
        self.session = session
        WatchFolder.shared.start(store: self)
    }

    func shutdown(completion: @escaping () -> Void) {
        guard let session else { completion(); return }
        session.shutdown(completion: completion)
    }

    func apply(_ statuses: [TorrentStatus], _ stats: SessionStats) {
        // Only drop selected ids that disappeared; a just-added transfer may not be in this snapshot yet.
        let removed = Set(transfers.map(\.id)).subtracting(statuses.map(\.id))
        if !removed.isEmpty { selection.subtract(removed) }
        transfers = statuses
        self.stats = stats
        recordTotals(stats)
        applySchedule()
        tick += 1
        speedHistory.append(SpeedSample(id: tick, down: Double(stats.downloadRate), up: Double(stats.uploadRate)))
        if speedHistory.count > 120 { speedHistory.removeFirst(speedHistory.count - 120) }
        var history: [InfoHash: [SpeedSample]] = [:]
        for t in statuses {
            var samples = transferHistory[t.id] ?? []
            samples.append(SpeedSample(id: tick, down: Double(t.downloadRate), up: Double(t.uploadRate)))
            if samples.count > 120 { samples.removeFirst(samples.count - 120) }
            history[t.id] = samples
        }
        transferHistory = history
        refreshDetails()
        DockController.shared.update(transfers: statuses, stats: stats, settings: settings)
        SleepGuard.shared.update(active: settings.preventSleep && statuses.contains { $0.state == .downloading || $0.state == .fetchingMetadata })
    }

    /// Adds this session's new bytes to the all-time totals.
    private func recordTotals(_ stats: SessionStats) {
        guard !DemoMode.isEnabled else { return }
        let down = stats.sessionDownloaded - lastSessionDownloaded
        let up = stats.sessionUploaded - lastSessionUploaded
        lastSessionDownloaded = stats.sessionDownloaded
        lastSessionUploaded = stats.sessionUploaded
        if down > 0 { settings.allTimeDownloaded += down }
        if up > 0 { settings.allTimeUploaded += up }
    }

    /// Switches Slow Mode as the schedule's window opens and closes, leaving manual changes in between alone.
    private func applySchedule() {
        guard settings.scheduleEnabled else { scheduleWasActive = nil; return }
        let active = settings.scheduleCovers(Date())
        if active != scheduleWasActive {
            if scheduleWasActive != nil || active { settings.slowMode = active }
            scheduleWasActive = active
        }
    }

    func refreshDetails() {
        guard selection.count == 1, let id = selection.first else {
            if details != nil { details = nil }
            return
        }
        if DemoMode.isEnabled {
            details = DemoMode.details(for: id)
            return
        }
        session?.details(for: id) { [weak self] details in
            guard let self, selection.first == id else { return }
            if self.details != details { self.details = details }
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .finished(let id, let name):
            var url = transfers.first { $0.id == id }?.contentURL
            if settings.moveCompletedEnabled, let folder = settings.moveCompletedFolder,
               let t = transfers.first(where: { $0.id == id }), t.savePath.standardizedFileURL != folder.standardizedFileURL {
                session?.move(id, to: folder) { [weak self] error in
                    if let error { self?.alert = AlertItem(title: "Couldn't Move “\(name)”", message: error.localizedDescription) }
                }
                url = t.contentURL.map { folder.appendingPathComponent($0.lastPathComponent) }
            }
            guard settings.notifyOnCompletion else { return }
            Notifier.shared.notifyFinished(name: name, url: url)
        case .failed(_, let name, let message):
            Notifier.shared.notifyFailed(name: name, message: message)
        case .metadataReceived:
            break
        }
    }

    // MARK: - Lists

    var visibleTransfers: [TorrentStatus] {
        var list = transfers.filter(filter.matches)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        let sorted: [TorrentStatus]
        switch settings.sort {
        case .queue: sorted = list
        case .name: sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateAdded: sorted = list.sorted { $0.addedDate < $1.addedDate }
        case .size: sorted = list.sorted { $0.totalSize < $1.totalSize }
        case .progress: sorted = list.sorted { $0.progress < $1.progress }
        case .downloadSpeed: sorted = list.sorted { $0.downloadRate > $1.downloadRate }
        case .uploadSpeed: sorted = list.sorted { $0.uploadRate > $1.uploadRate }
        case .ratio: sorted = list.sorted { $0.ratio < $1.ratio }
        }
        return settings.sortAscending ? sorted : sorted.reversed()
    }

    /// Whether rows can be dragged to reorder the queue: only while the list shows queue order.
    var canReorder: Bool {
        settings.sort == .queue && settings.sortAscending && searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Reorders the queue after rows were dragged in the (possibly filtered) list.
    func moveVisible(from source: IndexSet, to destination: Int) {
        var visible = visibleTransfers.map(\.id)
        visible.move(fromOffsets: source, toOffset: destination)
        // Hidden transfers keep their places; the visible ones fill their own slots in the new order.
        let shown = Set(visible)
        var next = visible.makeIterator()
        let order = transfers.map { shown.contains($0.id) ? next.next()! : $0.id }
        transfers = order.compactMap { id in transfers.first { $0.id == id } }
        if DemoMode.isEnabled { return }
        session?.setQueueOrder(order)
    }

    func count(for filter: TransferFilter) -> Int { transfers.filter(filter.matches).count }

    var selectedTransfers: [TorrentStatus] { transfers.filter { selection.contains($0.id) } }
    var selectedTransfer: TorrentStatus? { selection.count == 1 ? transfers.first { $0.id == selection.first } : nil }

    // MARK: - Adding

    /// Handles .torrent files and magnet links dropped, opened or pasted.
    func open(_ urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "magnet" {
                addMagnet(url.absoluteString)
            } else if url.isFileURL {
                addTorrentFile(at: url)
            }
        }
    }

    func addTorrentFile(at url: URL, ask: Bool? = nil) {
        do {
            let data = try Data(contentsOf: url)
            addTorrent(data: data, ask: ask)
        } catch {
            alert = AlertItem(title: "Couldn't Open “\(url.lastPathComponent)”", message: error.localizedDescription)
        }
    }

    func addTorrent(data: Data, ask: Bool? = nil) {
        do {
            let meta = try Metainfo(data: data)
            if transfers.contains(where: { $0.id == meta.info.infoHash }) {
                _ = try? session?.addTorrent(data: data) // merges trackers
                selectOnly(meta.info.infoHash)
                return
            }
            if ask ?? settings.showAddOptions {
                NSApp.activate()
                pendingTorrents.append(PendingTorrent(data: data, meta: meta))
            } else {
                try commit(data: data, folder: nil, priorities: nil, start: settings.startTransfersAutomatically)
            }
        } catch {
            alert = AlertItem(title: "Couldn't Add Torrent", message: error.localizedDescription)
        }
    }

    func commit(data: Data, folder: URL?, priorities: [FilePriority]?, start: Bool) throws {
        guard let session else { return }
        let id = try session.addTorrent(data: data, saveTo: folder, paused: !start, filePriorities: priorities)
        selectOnly(id)
    }

    @discardableResult
    func addMagnet(_ text: String) -> Bool {
        let link: MagnetLink
        do {
            link = try MagnetLink(text)
        } catch {
            alert = AlertItem(title: "Couldn't Add Magnet Link", message: error.localizedDescription)
            return false
        }
        if transfers.contains(where: { $0.id == link.infoHash }) {
            _ = try? session?.addMagnet(link)
            selectOnly(link.infoHash)
            return true
        }
        do {
            let id = try session?.addMagnet(link, paused: !settings.startTransfersAutomatically)
            if let id { selectOnly(id) }
            if clipboardMagnet?.infoHash == link.infoHash { clipboardMagnet = nil }
            return true
        } catch {
            alert = AlertItem(title: "Couldn't Add Magnet Link", message: error.localizedDescription)
            return false
        }
    }

    private func selectOnly(_ id: InfoHash) {
        filter = .all
        selection = [id]
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose torrent files to add"
        panel.prompt = "Add"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func presentMagnetSheet() {
        if let link = MagnetLink.find(in: NSPasteboard.general.string(forType: .string) ?? "") {
            magnetDraft = link.uri
        } else {
            magnetDraft = ""
        }
        showMagnetSheet = true
    }

    /// Notices a new magnet link on the clipboard and offers to add it.
    func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), let link = MagnetLink.find(in: text),
              !transfers.contains(where: { $0.id == link.infoHash }) else { return }
        withAnimation(.snappy) { clipboardMagnet = link }
    }

    // MARK: - Actions

    func targets(_ ids: [InfoHash]? = nil) -> [InfoHash] { ids ?? Array(selection) }

    func pause(_ ids: [InfoHash]? = nil) { session?.pause(targets(ids)) }
    func resume(_ ids: [InfoHash]? = nil) { session?.resume(targets(ids)) }
    func pauseAll() { session?.pauseAll() }
    func resumeAll() { session?.resumeAll() }
    func recheck(_ ids: [InfoHash]? = nil) { session?.recheck(targets(ids)) }
    func reannounce(_ ids: [InfoHash]? = nil) { session?.reannounce(targets(ids)) }
    func setSequential(_ ids: [InfoHash]? = nil, _ value: Bool) { session?.setSequential(targets(ids), value) }
    func moveToTop(_ ids: [InfoHash]? = nil) { session?.moveInQueue(targets(ids), toTop: true) }
    func moveToBottom(_ ids: [InfoHash]? = nil) { session?.moveInQueue(targets(ids), toTop: false) }

    func togglePause(_ ids: [InfoHash]? = nil) {
        let items = transfers.filter { targets(ids).contains($0.id) }
        if items.contains(where: { $0.state != .paused && $0.state != .finished && $0.state != .error }) {
            pause(items.map(\.id))
        } else {
            resume(items.map(\.id))
        }
    }

    func requestRemove(_ ids: [InfoHash]? = nil) {
        let list = targets(ids)
        guard !list.isEmpty else { return }
        removeRequest = list
    }

    func remove(_ ids: [InfoHash], deleteData: Bool) {
        for id in ids { session?.remove(id, deleteData: deleteData) }
        selection.subtract(ids)
        transfers.removeAll { ids.contains($0.id) }
    }

    func setFilePriorities(_ id: InfoHash, _ changes: [Int: FilePriority]) {
        session?.setFilePriorities(id, changes)
        if var details, details.id == id {
            for i in details.files.indices where changes[details.files[i].id] != nil {
                details.files[i].priority = changes[details.files[i].id]!
            }
            self.details = details
        }
    }

    func setRatioLimit(_ ids: [InfoHash]? = nil, _ limit: Double?) { session?.setRatioLimit(targets(ids), limit) }
    func setSpeedLimits(_ ids: [InfoHash]? = nil, download: Int?, upload: Int?) { session?.setSpeedLimits(targets(ids), download: download, upload: upload) }

    func reveal(_ ids: [InfoHash]? = nil) {
        let urls = transfers.filter { targets(ids).contains($0.id) }.map { t -> URL in
            if let url = t.contentURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return t.savePath
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The transfer's file or folder, if any of it is on disk yet.
    func existingContentURL(_ id: InfoHash) -> URL? {
        guard let url = transfers.first(where: { $0.id == id })?.contentURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func openContent(_ id: InfoHash) {
        if let url = existingContentURL(id) { NSWorkspace.shared.open(url) }
    }

    func copyMagnetLinks(_ ids: [InfoHash]? = nil) {
        let links = transfers.filter { targets(ids).contains($0.id) }.map(\.magnetLink)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        lastPasteboardChange = NSPasteboard.general.changeCount
    }

    func exportTorrentFile(_ id: InfoHash) {
        guard let t = transfers.first(where: { $0.id == id }), let data = session?.torrentFile(for: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.name).torrent"
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    func move(_ id: InfoHash) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a new location for the downloaded files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session?.move(id, to: url) { [weak self] error in
            if let error { self?.alert = AlertItem(title: "Couldn't Move Files", message: error.localizedDescription) }
        }
    }

    func addTrackers(_ id: InfoHash, _ text: String) {
        let urls = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        session?.addTrackers(id, urls)
    }

    func removeTracker(_ id: InfoHash, _ url: String) { session?.removeTracker(id, url) }

    /// Lets the menu bar extra and intents bring the main window back.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
}
