import MurmurKit
import SwiftUI

enum SettingsTab: String, Hashable { case general, transfers, network }

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) { TransferSettings() }
            Tab("Network", systemImage: "network", value: .network) { NetworkSettings() }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: clearFocus)
        .onChange(of: tab) { clearFocus() }
    }

    /// AppKit focuses the first text field when a pane appears, which looks like a stray selection.
    private func clearFocus() {
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow, window.firstResponder is NSText { window.makeFirstResponder(nil) }
        }
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var isDefault = DefaultApp.isDefault

    var body: some View {
        Form {
            Section {
                LabeledContent("Download to") {
                    FolderButton(url: settings.downloadFolder) { settings.downloadFolder = $0 }
                }
                Toggle("Show files and location before adding a torrent", isOn: $settings.showAddOptions)
                Toggle("Start transfers automatically", isOn: $settings.startTransfersAutomatically)
                Toggle("Move finished downloads", isOn: $settings.moveCompletedEnabled)
                if settings.moveCompletedEnabled {
                    LabeledContent("Move to") {
                        FolderButton(url: settings.moveCompletedFolder, placeholder: "Choose…") { settings.moveCompletedFolder = $0 }
                    }
                }
            }
            Section {
                LabeledContent {
                    if isDefault {
                        Label("Murmur is the default", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            Task {
                                await DefaultApp.makeDefault()
                                isDefault = DefaultApp.isDefault
                            }
                        }
                    }
                } label: {
                    Text("Magnet links and .torrent files")
                    Text("Open them in Murmur from your browser and Finder.")
                }
                Toggle(isOn: $settings.watchFolderEnabled) {
                    Text("Add torrents from a folder automatically")
                    Text("New .torrent files are added, then renamed to .torrent.added.")
                }
                if settings.watchFolderEnabled {
                    LabeledContent("Watch") {
                        FolderButton(url: settings.watchFolder, placeholder: "Choose…") { settings.watchFolder = $0 }
                    }
                }
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)
                Toggle("Show speed in menu bar", isOn: $settings.showSpeedInMenuBar)
                    .disabled(!settings.showMenuBarExtra)
                Toggle("Show download count on Dock icon", isOn: $settings.showDockBadge)
                Toggle("Notify when downloads finish", isOn: $settings.notifyOnCompletion)
                    .onChange(of: settings.notifyOnCompletion) { _, on in if on { Notifier.shared.requestAuthorization() } }
                Toggle("Keep Mac awake while downloading", isOn: $settings.preventSleep)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { isDefault = DefaultApp.isDefault }
    }
}

private struct ExtraTrackersEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extra trackers").font(.headline)
            Text("One URL per line. They're added to new public torrents; private ones are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(width: 380, height: 140)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            Button("Add Popular Public Trackers") {
                let popular = ["udp://tracker.opentrackr.org:1337/announce", "udp://open.demonii.com:1337/announce", "udp://open.stealth.si:80/announce",
                               "udp://tracker.torrent.eu.org:451/announce", "udp://exodus.desync.com:6969/announce", "udp://tracker.openbittorrent.com:6969/announce"]
                var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for url in popular where !lines.contains(url) { lines.append(url) }
                text = lines.joined(separator: "\n")
            }
            .controlSize(.small)
        }
        .padding(14)
    }
}

/// Hours and minutes stored as minutes after midnight.
private struct TimePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("", selection: Binding(get: {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
    }
}

private struct WeekdayPicker: View {
    @Binding var days: Set<Int>

    var body: some View {
        HStack(spacing: 4) {
            // Start the week where the user's calendar does.
            let calendar = Calendar.current
            let symbols = calendar.veryShortWeekdaySymbols
            ForEach(0..<7, id: \.self) { offset in
                let day = (calendar.firstWeekday - 1 + offset) % 7 + 1
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(on ? Color.white : .primary)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private struct TransferSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Speed limits") {
                LimitRow(title: "Download", enabled: $settings.limitDownload, value: $settings.downloadLimitKB)
                LimitRow(title: "Upload", enabled: $settings.limitUpload, value: $settings.uploadLimitKB)
            }
            Section {
                Toggle(isOn: $settings.slowMode) {
                    Label("Slow Mode", systemImage: "tortoise")
                    Text("Use these limits instead, with the tortoise button or ⇧⌘T.")
                }
                LabeledContent("Download") { KBField(value: $settings.slowDownloadKB) }
                LabeledContent("Upload") { KBField(value: $settings.slowUploadKB) }
                Toggle("Turn on automatically", isOn: $settings.scheduleEnabled)
                if settings.scheduleEnabled {
                    LabeledContent("From") {
                        HStack {
                            TimePicker(minutes: $settings.scheduleStart)
                            Text("to").foregroundStyle(.secondary)
                            TimePicker(minutes: $settings.scheduleEnd)
                        }
                    }
                    LabeledContent("On") { WeekdayPicker(days: $settings.scheduleDays) }
                }
            }
            Section("Queue and seeding") {
                StepperRow(title: "Download at once", value: $settings.maxActiveDownloads, range: 0...50,
                           text: settings.maxActiveDownloads == 0 ? "No limit" : "\(settings.maxActiveDownloads)")
                Toggle("Stop seeding at ratio", isOn: $settings.stopAtRatio)
                if settings.stopAtRatio {
                    LabeledContent("Ratio") {
                        HStack(spacing: 6) {
                            Text(Format.ratio(settings.ratioLimit)).monospacedDigit()
                            Stepper("Ratio", value: $settings.ratioLimit, in: 0.1...20, step: 0.1).labelsHidden()
                        }
                    }
                }
                StepperRow(title: "Peers per transfer", value: $settings.maxPeersPerTorrent, range: 10...300, step: 10,
                           text: "\(settings.maxPeersPerTorrent)")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct NetworkSettings: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(TransferStore.self) private var store
    @State private var portText = ""
    @State private var interfaces = NetworkInterfaces.list()
    @State private var editingTrackers = false

    private var encryptionHelp: String {
        switch settings.encryption {
        case .preferred: "Encrypts when the peer supports it, which keeps your provider from singling out torrent traffic."
        case .required: "Only connects to peers that encrypt. You may find fewer peers."
        case .disabled: "Connects in plaintext, but still accepts encrypted connections."
        }
    }

    private var extraTrackerSummary: String {
        let count = settings.extraTrackers.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return count == 0 ? "Add your own trackers to every public torrent." : "\(count) tracker\(count == 1 ? "" : "s") added to every public torrent."
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Listening port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .frame(width: 70)
                            .labelsHidden()
                            .onSubmit(applyPort)
                        Button("Random") {
                            settings.listenPort = Int.random(in: 49160...65000)
                            portText = "\(settings.listenPort)"
                        }
                    }
                }
                LabeledContent("Status") {
                    let stats = store.stats
                    if stats.incomingConnections > 0 || stats.portMapping == "NAT-PMP" || stats.portMapping == "UPnP" {
                        Label(stats.portMapping.map { "Open (\($0))" } ?? "Open", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if stats.isListening {
                        Label("Listening, may be blocked by your router", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    } else {
                        Label("Not listening", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Toggle(isOn: $settings.enablePortMapping) {
                    Text("Open the port on my router")
                    Text("Uses NAT-PMP or UPnP so other peers can reach you.")
                }
            }
            Section {
                Picker(selection: $settings.encryption) {
                    Text("Prefer encryption").tag(EncryptionMode.preferred)
                    Text("Require encryption").tag(EncryptionMode.required)
                    Text("Don't encrypt").tag(EncryptionMode.disabled)
                } label: {
                    Text("Encryption")
                    Text(encryptionHelp)
                }
            }
            Section("Finding peers") {
                Toggle(isOn: $settings.enableDHT) {
                    Text("Distributed hash table (DHT)")
                    Text("Find peers without trackers. Needed for most magnet links.")
                }
                Toggle(isOn: $settings.enablePEX) {
                    Text("Peer exchange (PEX)")
                    Text("Learn about more peers from the ones you're connected to.")
                }
                Toggle(isOn: $settings.enableLocalDiscovery) {
                    Text("Local peer discovery")
                    Text("Find peers on your own network, like other Macs at home.")
                }
                LabeledContent {
                    Button("Edit…") { editingTrackers = true }
                        .popover(isPresented: $editingTrackers) { ExtraTrackersEditor(text: $settings.extraTrackers) }
                } label: {
                    Text("Extra trackers")
                    Text(extraTrackerSummary)
                }
            }
            Section {
                Picker(selection: $settings.networkInterface) {
                    Text("Any").tag("")
                    ForEach(interfaces, id: \.name) { item in
                        Text(item.label).tag(item.name)
                    }
                    if !settings.networkInterface.isEmpty && !interfaces.contains(where: { $0.name == settings.networkInterface }) {
                        Text("\(settings.networkInterface) (not connected)").tag(settings.networkInterface)
                    }
                } label: {
                    Text("Network interface")
                    Text("Bind to your VPN’s interface (usually utun) and Murmur stops transferring whenever it disconnects.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear {
            portText = "\(settings.listenPort)"
            interfaces = NetworkInterfaces.list()
        }
    }

    private func applyPort() {
        if let port = Int(portText), (1024...65535).contains(port) {
            settings.listenPort = port
        } else {
            portText = "\(settings.listenPort)"
        }
    }
}

/// A speed limit: the switch turns it on, the field sets it.
private struct LimitRow: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                KBField(value: $value).disabled(!enabled)
                Toggle(title, isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

/// A value shown next to its stepper, on the trailing side like the other controls.
private struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let text: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

private struct KBField: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            TextField("KB/s", value: $value, format: .number)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            Text("KB/s").foregroundStyle(.secondary)
        }
    }
}

private struct FolderButton: View {
    let url: URL?
    var placeholder = "Choose…"
    let onChange: (URL) -> Void

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = url
            if panel.runModal() == .OK, let chosen = panel.url { onChange(chosen) }
        } label: {
            HStack(spacing: 6) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    Text(url.lastPathComponent)
                } else {
                    Text(placeholder)
                }
            }
        }
        .help(url?.path ?? "")
    }
}

/// Active network interfaces with an address, for binding to a VPN.
enum NetworkInterfaces {
    struct Item { let name: String; let label: String }

    static func list() -> [Item] {
        var result: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let flags = Int32(item.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: item.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                let kind = name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") ? "VPN" : (name.hasPrefix("en") ? "Ethernet / Wi‑Fi" : "")
                result[name] = kind.isEmpty ? "\(name) (\(ip))" : "\(name): \(kind) (\(ip))"
            }
            cursor = item.pointee.ifa_next
        }
        return result.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { Item(name: $0.key, label: $0.value) }
    }
}
