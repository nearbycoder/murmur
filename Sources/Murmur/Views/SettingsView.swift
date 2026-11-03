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
            }
            Section("Queue and seeding") {
                Stepper(value: $settings.maxActiveDownloads, in: 0...50) {
                    LabeledContent("Download at once", value: settings.maxActiveDownloads == 0 ? "No limit" : "\(settings.maxActiveDownloads)")
                }
                Toggle("Stop seeding at ratio", isOn: $settings.stopAtRatio)
                if settings.stopAtRatio {
                    Stepper(value: $settings.ratioLimit, in: 0.1...20, step: 0.1) {
                        LabeledContent("Ratio", value: Format.ratio(settings.ratioLimit))
                    }
                }
                Stepper(value: $settings.maxPeersPerTorrent, in: 10...300, step: 10) {
                    LabeledContent("Peers per transfer", value: "\(settings.maxPeersPerTorrent)")
                }
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
            Section("Finding peers") {
                Toggle(isOn: $settings.enableDHT) {
                    Text("Distributed hash table (DHT)")
                    Text("Find peers without trackers. Needed for most magnet links.")
                }
                Toggle(isOn: $settings.enablePEX) {
                    Text("Peer exchange (PEX)")
                    Text("Learn about more peers from the ones you're connected to.")
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

private struct LimitRow: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var value: Int

    var body: some View {
        LabeledContent {
            KBField(value: $value).disabled(!enabled)
        } label: {
            Toggle(title, isOn: $enabled)
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
