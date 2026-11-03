import MurmurKit
import SwiftUI

struct MenuBarLabel: View {
    let store: TransferStore
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = store.transfers.contains { $0.state == .downloading }
        HStack(spacing: 4) {
            Image(systemName: active ? "arrow.down.circle.fill" : "arrow.down.circle")
            if settings.showSpeedInMenuBar && (store.stats.downloadRate > 0 || store.stats.uploadRate > 0) {
                Text("↓\(store.stats.downloadRate.speed) ↑\(store.stats.uploadRate.speed)")
                    .monospacedDigit()
            }
        }
        .onAppear {
            if store.openMainWindow == nil { store.openMainWindow = { openWindow(id: "main") } }
        }
    }
}

struct MenuBarView: View {
    @Environment(TransferStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var settings = store.settings
        let active = store.transfers.filter { $0.state == .downloading || $0.state == .fetchingMetadata || $0.state == .checking }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Download").font(.caption).foregroundStyle(.secondary)
                    Text(store.stats.downloadRate.speed)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Upload").font(.caption).foregroundStyle(.secondary)
                    Text(store.stats.uploadRate.speed)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
            }
            SpeedChart(samples: store.speedHistory, showsAxis: false)
                .frame(height: 44)

            if active.isEmpty {
                Text(store.transfers.isEmpty ? "No transfers" : "Nothing downloading")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(active.prefix(5)) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(t.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.percent(t.displayProgress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            TransferProgressBar(progress: t.displayProgress, tint: t.state.tint, height: 4)
                        }
                    }
                    if active.count > 5 {
                        Text("and \(active.count - 5) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { store.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }
                    Button { store.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                    Spacer()
                    Toggle(isOn: $settings.slowMode) { Image(systemName: "tortoise") }
                        .toggleStyle(.button)
                        .help("Slow Mode")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            HStack {
                Button("Add from Clipboard") {
                    if let link = MagnetLink.find(in: NSPasteboard.general.string(forType: .string) ?? "") {
                        store.addMagnet(link.uri)
                    } else {
                        openMain()
                        store.presentMagnetSheet()
                    }
                }
                Spacer()
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Button("Open Murmur") { openMain() }
                    .keyboardShortcut("o")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
