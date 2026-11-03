import AppIntents
import MurmurKit

/// Shortcuts and Spotlight actions.
struct AddMagnetLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Magnet Link"
    static let description = IntentDescription("Starts downloading a magnet link in Murmur.")

    @Parameter(title: "Magnet Link")
    var link: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = TransferStore.shared
        store.start()
        guard store.addMagnet(link) else { throw MagnetError.notAMagnet }
        return .result()
    }
}

struct PauseAllTransfersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause All Transfers"
    static let description = IntentDescription("Pauses every download and upload in Murmur.")

    @MainActor
    func perform() async throws -> some IntentResult {
        TransferStore.shared.pauseAll()
        return .result()
    }
}

struct ResumeAllTransfersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume All Transfers"
    static let description = IntentDescription("Resumes every paused transfer in Murmur.")

    @MainActor
    func perform() async throws -> some IntentResult {
        TransferStore.shared.resumeAll()
        return .result()
    }
}

struct ToggleSlowModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Slow Mode"
    static let description = IntentDescription("Switches Murmur's alternative speed limits on or off.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        AppSettings.shared.slowMode.toggle()
        return .result(value: AppSettings.shared.slowMode)
    }
}

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PauseAllTransfersIntent(), phrases: ["Pause all transfers in \(.applicationName)"], shortTitle: "Pause All", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAllTransfersIntent(), phrases: ["Resume transfers in \(.applicationName)"], shortTitle: "Resume All", systemImageName: "play.circle")
        AppShortcut(intent: ToggleSlowModeIntent(), phrases: ["Toggle slow mode in \(.applicationName)"], shortTitle: "Slow Mode", systemImageName: "tortoise")
    }
}
