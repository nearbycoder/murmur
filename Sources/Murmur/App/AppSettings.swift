import AppKit
import MurmurKit
import Observation
import ServiceManagement

/// Preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    /// Show file selection and location before adding a .torrent file.
    var showAddOptions: Bool { didSet { defaults.set(showAddOptions, forKey: "showAddOptions") } }
    var startTransfersAutomatically: Bool { didSet { defaults.set(startTransfersAutomatically, forKey: "startTransfersAutomatically") } }

    var limitDownload: Bool { didSet { defaults.set(limitDownload, forKey: "limitDownload"); apply() } }
    var downloadLimitKB: Int { didSet { defaults.set(downloadLimitKB, forKey: "downloadLimitKB"); apply() } }
    var limitUpload: Bool { didSet { defaults.set(limitUpload, forKey: "limitUpload"); apply() } }
    var uploadLimitKB: Int { didSet { defaults.set(uploadLimitKB, forKey: "uploadLimitKB"); apply() } }
    /// Slow mode: alternative limits for when you need the bandwidth (the tortoise button).
    var slowMode: Bool { didSet { defaults.set(slowMode, forKey: "slowMode"); apply() } }
    var slowDownloadKB: Int { didSet { defaults.set(slowDownloadKB, forKey: "slowDownloadKB"); apply() } }
    var slowUploadKB: Int { didSet { defaults.set(slowUploadKB, forKey: "slowUploadKB"); apply() } }

    var stopAtRatio: Bool { didSet { defaults.set(stopAtRatio, forKey: "stopAtRatio"); apply() } }
    var ratioLimit: Double { didSet { defaults.set(ratioLimit, forKey: "ratioLimit"); apply() } }
    var maxActiveDownloads: Int { didSet { defaults.set(maxActiveDownloads, forKey: "maxActiveDownloads"); apply() } }
    var maxPeersPerTorrent: Int { didSet { defaults.set(maxPeersPerTorrent, forKey: "maxPeersPerTorrent"); apply() } }

    var listenPort: Int { didSet { defaults.set(listenPort, forKey: "listenPort"); apply() } }
    var enableDHT: Bool { didSet { defaults.set(enableDHT, forKey: "enableDHT"); apply() } }
    var enablePEX: Bool { didSet { defaults.set(enablePEX, forKey: "enablePEX"); apply() } }
    var enablePortMapping: Bool { didSet { defaults.set(enablePortMapping, forKey: "enablePortMapping"); apply() } }
    /// Bind to one interface, such as a VPN. Empty means any.
    var networkInterface: String { didSet { defaults.set(networkInterface, forKey: "networkInterface"); apply() } }

    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") } }
    var showSpeedInMenuBar: Bool { didSet { defaults.set(showSpeedInMenuBar, forKey: "showSpeedInMenuBar") } }
    var showDockBadge: Bool { didSet { defaults.set(showDockBadge, forKey: "showDockBadge") } }
    var notifyOnCompletion: Bool { didSet { defaults.set(notifyOnCompletion, forKey: "notifyOnCompletion") } }
    var preventSleep: Bool { didSet { defaults.set(preventSleep, forKey: "preventSleep") } }
    var watchFolderEnabled: Bool { didSet { defaults.set(watchFolderEnabled, forKey: "watchFolderEnabled") } }
    var watchFolder: URL? { didSet { defaults.set(watchFolder?.path, forKey: "watchFolder") } }
    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }

    var encryption: EncryptionMode { didSet { defaults.set(encryption.rawValue, forKey: "encryption"); apply() } }
    var enableLocalDiscovery: Bool { didSet { defaults.set(enableLocalDiscovery, forKey: "enableLocalDiscovery"); apply() } }
    /// One tracker URL per line, added to every public torrent.
    var extraTrackers: String { didSet { defaults.set(extraTrackers, forKey: "extraTrackers"); apply() } }
    var moveCompletedEnabled: Bool { didSet { defaults.set(moveCompletedEnabled, forKey: "moveCompletedEnabled") } }
    var moveCompletedFolder: URL? { didSet { defaults.set(moveCompletedFolder?.path, forKey: "moveCompletedFolder") } }
    /// Turn Slow Mode on automatically between two times on chosen days.
    var scheduleEnabled: Bool { didSet { defaults.set(scheduleEnabled, forKey: "scheduleEnabled") } }
    var scheduleStart: Int { didSet { defaults.set(scheduleStart, forKey: "scheduleStart") } }
    var scheduleEnd: Int { didSet { defaults.set(scheduleEnd, forKey: "scheduleEnd") } }
    /// Calendar weekdays (1 is Sunday).
    var scheduleDays: Set<Int> { didSet { defaults.set(Array(scheduleDays), forKey: "scheduleDays") } }
    /// Totals across every launch.
    var allTimeDownloaded: Int64 { didSet { defaults.set(Double(allTimeDownloaded), forKey: "allTimeDownloaded") } }
    var allTimeUploaded: Int64 { didSet { defaults.set(Double(allTimeUploaded), forKey: "allTimeUploaded") } }
    let firstLaunch: Date

    /// Called whenever an engine setting changes.
    @ObservationIgnored var onEngineChange: (() -> Void)?

    private init() {
        defaults = DemoMode.isEnabled ? UserDefaults(suiteName: "dev.nearby.Murmur.demo")! : .standard
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        defaults.register(defaults: [
            "showAddOptions": true,
            "startTransfersAutomatically": true,
            "downloadLimitKB": 5000,
            "uploadLimitKB": 1000,
            "slowDownloadKB": 500,
            "slowUploadKB": 50,
            "ratioLimit": 2.0,
            "maxActiveDownloads": 4,
            "maxPeersPerTorrent": 60,
            "enableDHT": true,
            "enablePEX": true,
            "enablePortMapping": true,
            "showMenuBarExtra": true,
            "showDockBadge": true,
            "notifyOnCompletion": true,
            "preventSleep": true,
            "encryption": EncryptionMode.preferred.rawValue,
            "enableLocalDiscovery": true,
            "scheduleStart": 9 * 60,
            "scheduleEnd": 17 * 60,
            "scheduleDays": [2, 3, 4, 5, 6],
        ])
        downloadFolder = defaults.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0) } ?? downloads
        showAddOptions = defaults.bool(forKey: "showAddOptions")
        startTransfersAutomatically = defaults.bool(forKey: "startTransfersAutomatically")
        limitDownload = defaults.bool(forKey: "limitDownload")
        downloadLimitKB = defaults.integer(forKey: "downloadLimitKB")
        limitUpload = defaults.bool(forKey: "limitUpload")
        uploadLimitKB = defaults.integer(forKey: "uploadLimitKB")
        slowMode = defaults.bool(forKey: "slowMode")
        slowDownloadKB = defaults.integer(forKey: "slowDownloadKB")
        slowUploadKB = defaults.integer(forKey: "slowUploadKB")
        stopAtRatio = defaults.bool(forKey: "stopAtRatio")
        ratioLimit = defaults.double(forKey: "ratioLimit")
        maxActiveDownloads = defaults.integer(forKey: "maxActiveDownloads")
        maxPeersPerTorrent = defaults.integer(forKey: "maxPeersPerTorrent")
        enableDHT = defaults.bool(forKey: "enableDHT")
        enablePEX = defaults.bool(forKey: "enablePEX")
        enablePortMapping = defaults.bool(forKey: "enablePortMapping")
        networkInterface = defaults.string(forKey: "networkInterface") ?? ""
        showMenuBarExtra = defaults.bool(forKey: "showMenuBarExtra")
        showSpeedInMenuBar = defaults.bool(forKey: "showSpeedInMenuBar")
        showDockBadge = defaults.bool(forKey: "showDockBadge")
        notifyOnCompletion = defaults.bool(forKey: "notifyOnCompletion")
        preventSleep = defaults.bool(forKey: "preventSleep")
        watchFolderEnabled = defaults.bool(forKey: "watchFolderEnabled")
        watchFolder = defaults.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0) }
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        encryption = EncryptionMode(rawValue: defaults.string(forKey: "encryption") ?? "") ?? .preferred
        enableLocalDiscovery = defaults.bool(forKey: "enableLocalDiscovery")
        extraTrackers = defaults.string(forKey: "extraTrackers") ?? ""
        moveCompletedEnabled = defaults.bool(forKey: "moveCompletedEnabled")
        moveCompletedFolder = defaults.string(forKey: "moveCompletedFolder").map { URL(fileURLWithPath: $0) }
        scheduleEnabled = defaults.bool(forKey: "scheduleEnabled")
        scheduleStart = defaults.integer(forKey: "scheduleStart")
        scheduleEnd = defaults.integer(forKey: "scheduleEnd")
        scheduleDays = Set(defaults.array(forKey: "scheduleDays") as? [Int] ?? [])
        allTimeDownloaded = Int64(defaults.double(forKey: "allTimeDownloaded"))
        allTimeUploaded = Int64(defaults.double(forKey: "allTimeUploaded"))
        if let first = defaults.object(forKey: "firstLaunch") as? Date {
            firstLaunch = first
        } else {
            firstLaunch = Date()
            defaults.set(firstLaunch, forKey: "firstLaunch")
        }
        // Pick a random high port once, so it stays the same across launches (and router mappings).
        var port = defaults.integer(forKey: "listenPort")
        if port == 0 {
            port = Int.random(in: 49160...65000)
            defaults.set(port, forKey: "listenPort")
        }
        listenPort = port
    }

    private func apply() { onEngineChange?() }

    static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(DemoMode.isEnabled ? "Murmur Demo" : "Murmur", isDirectory: true)
    }

    var engineConfiguration: Session.Configuration {
        var config = Session.Configuration(downloadDirectory: downloadFolder, stateDirectory: AppSettings.stateDirectory)
        config.listenPort = UInt16(clamping: listenPort)
        config.enableDHT = enableDHT
        config.enablePEX = enablePEX
        config.enablePortMapping = enablePortMapping
        if slowMode {
            config.maxDownloadRate = slowDownloadKB * 1024
            config.maxUploadRate = slowUploadKB * 1024
        } else {
            config.maxDownloadRate = limitDownload ? downloadLimitKB * 1024 : 0
            config.maxUploadRate = limitUpload ? uploadLimitKB * 1024 : 0
        }
        config.maxActiveDownloads = maxActiveDownloads
        config.maxPeersPerTorrent = maxPeersPerTorrent
        config.seedRatioLimit = stopAtRatio ? ratioLimit : nil
        config.networkInterface = networkInterface.isEmpty ? nil : networkInterface
        config.encryption = encryption
        config.enableLocalDiscovery = enableLocalDiscovery
        config.extraTrackers = extraTrackers.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return config
    }

    /// Whether the Slow Mode schedule covers this moment. Windows that cross midnight count from the start day.
    func scheduleCovers(_ date: Date) -> Bool {
        AppSettings.schedule(covers: date, start: scheduleStart, end: scheduleEnd, days: scheduleDays)
    }

    nonisolated static func schedule(covers date: Date, start: Int, end: Int, days: Set<Int>, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = parts.weekday ?? 1
        if start <= end {
            return days.contains(weekday) && minute >= start && minute < end
        }
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (days.contains(weekday) && minute >= start) || (days.contains(yesterday) && minute < end)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Murmur: failed to update login item: \(error)")
            }
        }
    }
}
