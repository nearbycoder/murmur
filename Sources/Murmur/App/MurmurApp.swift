import MurmurKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = TransferStore.shared
    @State private var settings = AppSettings.shared

    var body: some Scene {
        Window("Murmur", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 940, minHeight: 480)
        }
        .defaultSize(width: 1120, height: 700)
        .windowToolbarStyle(.unified)
        .commands { MurmurCommands(store: store, settings: settings) }

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra(isInserted: $settings.showMenuBarExtra) {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        TransferStore.shared.start()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        let store = TransferStore.shared
        store.start()
        store.open(urls)
        if !store.pendingTorrents.isEmpty || NSApp.windows.allSatisfy({ !$0.isVisible }) {
            store.openMainWindow?()
            NSApp.activate()
        }
    }

    // Keep seeding after the window closes; the menu bar extra and Dock bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { TransferStore.shared.openMainWindow?() }
        return true
    }

    /// Right-clicking the Dock icon: quick controls and what's downloading.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let store = TransferStore.shared
        let menu = NSMenu()
        let downloading = store.transfers.filter { $0.state == .downloading || $0.state == .fetchingMetadata }
        for t in downloading.prefix(6) {
            let title = t.hasMetadata ? "\(t.name) — \(Format.percent(t.displayProgress))" : t.name
            let item = ClosureMenuItem(title: title) {
                store.filter = .all
                store.selection = [t.id]
                store.openMainWindow?()
                NSApp.activate()
            }
            menu.addItem(item)
        }
        if !downloading.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Add Magnet Link…") {
            store.openMainWindow?()
            NSApp.activate()
            store.presentMagnetSheet()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Resume All") { store.resumeAll() })
        menu.addItem(ClosureMenuItem(title: "Pause All") { store.pauseAll() })
        let slow = ClosureMenuItem(title: "Slow Mode") { store.settings.slowMode.toggle() }
        slow.state = store.settings.slowMode ? .on : .off
        menu.addItem(slow)
        return menu
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        TransferStore.shared.checkClipboard()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save resume data and tell trackers we're leaving before quitting.
        TransferStore.shared.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// An AppKit menu item that runs a closure, for menus built in code.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor @objc private func run() { handler() }
}

struct MurmurCommands: Commands {
    let store: TransferStore
    @Bindable var settings: AppSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Torrent File…") { store.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Add Magnet Link…") { store.presentMagnetSheet() }
                .keyboardShortcut("u")
            Divider()
            Button("Create Torrent…") { store.showCreateSheet = true }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Magnet Link") { store.copyMagnetLinks() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
        }
        CommandMenu("Transfers") {
            Button("Pause") { store.pause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
            Button("Resume") { store.resume() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Pause All") { store.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            Button("Resume All") { store.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Divider()
            Button("Show in Finder") { store.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Verify Local Data") { store.recheck() }
                .disabled(store.selection.isEmpty)
            Button("Ask Trackers for More Peers") { store.reannounce() }
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Move to Top of Queue") { store.moveToTop() }
                .disabled(store.selection.isEmpty)
            Button("Move to Bottom of Queue") { store.moveToBottom() }
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Remove…") { store.requestRemove() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection.isEmpty)
            Divider()
            Toggle("Slow Mode", isOn: $settings.slowMode)
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(TransferFilter.allCases.enumerated()), id: \.element) { index, filter in
                Button(filter.title) { store.filter = filter }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Menu("Sort By") { SortMenuContent(settings: settings) }
            Divider()
            Button(store.inspectorVisible ? "Hide Inspector" : "Show Inspector") { store.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
