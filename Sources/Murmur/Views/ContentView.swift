import MurmurKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TransferStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false
    @State private var showWelcome = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            TransferListView()
                .inspector(isPresented: store.transfers.isEmpty ? .constant(false) : $store.inspectorVisible) {
                    InspectorView()
                        .frame(minWidth: 0, maxWidth: .infinity) // the column width rules, never the content (see StatusFooter)
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                }
        }
        .toolbar { toolbar }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted { DropOverlay().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .sheet(item: Binding(get: { store.pendingTorrents.first }, set: { if $0 == nil, !store.pendingTorrents.isEmpty { store.pendingTorrents.removeFirst() } })) { pending in
            AddTorrentSheet(pending: pending)
        }
        .sheet(isPresented: $store.showMagnetSheet) { AddMagnetSheet() }
        .sheet(isPresented: $store.showCreateSheet) { CreateTorrentSheet() }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { store.settings.hasOnboarded = true; showWelcome = false }
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { store.removeRequest != nil }, set: { if !$0 { store.removeRequest = nil } }), titleVisibility: .visible) {
            Button("Remove") { if let ids = store.removeRequest { store.remove(ids, deleteData: false) } }
                .keyboardShortcut(.defaultAction)
            Button("Remove and Move Files to Trash", role: .destructive) { if let ids = store.removeRequest { store.remove(ids, deleteData: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing keeps the downloaded files unless you move them to the Trash.")
        }
        .onAppear {
            store.openMainWindow = { openWindow(id: "main") }
            store.openSettings = { openSettings() }
            if !store.settings.hasOnboarded && !DemoMode.isEnabled { showWelcome = true }
        }
    }

    private var removeTitle: String {
        let ids = store.removeRequest ?? []
        if ids.count == 1, let t = store.transfers.first(where: { $0.id == ids[0] }) { return "Remove “\(t.name)”?" }
        return "Remove \(ids.count) transfers?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Open Torrent File…", systemImage: "doc.badge.plus") { store.presentOpenPanel() }
                Button("Add Magnet Link…", systemImage: "link.badge.plus") { store.presentMagnetSheet() }
                Divider()
                Button("Create Torrent…", systemImage: "square.and.arrow.up.on.square") { store.showCreateSheet = true }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                store.presentOpenPanel()
            }
            .help("Add a torrent file (hold for more options)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                SortMenuContent(settings: store.settings)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort transfers by \(store.settings.sort.title.lowercased())")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            let selected = store.selectedTransfers
            let canPause = selected.contains { ![.paused, .finished, .error].contains($0.state) }
            Button {
                store.togglePause()
            } label: {
                Label(canPause || selected.isEmpty ? "Pause" : "Resume", systemImage: canPause || selected.isEmpty ? "pause.fill" : "play.fill")
            }
            .disabled(selected.isEmpty)
            .help(canPause ? "Pause the selected transfers" : "Resume the selected transfers")

            Button {
                store.requestRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
            .help("Remove the selected transfers")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            @Bindable var settings = store.settings
            Toggle(isOn: $settings.slowMode) {
                Label("Slow Mode", systemImage: "tortoise")
            }
            .help(settings.slowMode ? "Slow Mode is on: \(settings.slowDownloadKB) KB/s down, \(settings.slowUploadKB) KB/s up" : "Slow Mode: use your alternative speed limits")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in TransferStore.shared.open([url]) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let link = MagnetLink.find(in: text) else { return }
                    Task { @MainActor in TransferStore.shared.addMagnet(link.uri) }
                }
            }
        }
        return true
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Drop to Add")
                    .font(.title2.weight(.semibold))
                Text("Torrent files and magnet links")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(14)
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(TransferStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.filter }, set: { if let f = $0 { store.filter = f } })) {
            Section("Transfers") {
                ForEach(TransferFilter.allCases.filter { $0 != .errors || store.count(for: .errors) > 0 }) { filter in
                    Label(filter.title, systemImage: filter.symbol)
                        .badge(store.count(for: filter))
                        .tag(Optional(filter))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpeedCard()
                .padding(10)
        }
    }
}

/// Live session speeds with a small graph, pinned under the sidebar.
private struct SpeedCard: View {
    @Environment(TransferStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                rate("arrow.down", store.stats.downloadRate, .accentColor)
                rate("arrow.up", store.stats.uploadRate, .green)
            }
            SpeedChart(samples: store.speedHistory, showsAxis: false)
                .frame(height: 38)
            if store.settings.slowMode {
                Label("Slow Mode", systemImage: "tortoise.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading) // never wider than the sidebar (see StatusFooter)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func rate(_ symbol: String, _ value: Int64, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(value.speed)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
        }
    }
}
