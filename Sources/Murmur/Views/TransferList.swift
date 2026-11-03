import MurmurKit
import SwiftUI

struct TransferListView: View {
    @Environment(TransferStore.self) private var store
    @State private var quickLookURL: URL?

    var body: some View {
        @Bindable var store = store
        let visible = store.visibleTransfers
        Group {
            if store.transfers.isEmpty {
                EmptyStateView()
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label(store.searchText.isEmpty ? "No \(store.filter.title)" : "No Results", systemImage: store.searchText.isEmpty ? store.filter.symbol : "magnifyingglass")
                } description: {
                    Text(store.searchText.isEmpty ? "Transfers show up here when they’re \(store.filter.title.lowercased())." : "No transfers match “\(store.searchText)”.")
                }
            } else {
                List(selection: $store.selection) {
                    ForEach(visible) { status in
                        TransferRow(status: status)
                            .tag(status.id)
                            .listRowSeparator(.visible)
                    }
                    .onMove(perform: store.canReorder ? { store.moveVisible(from: $0, to: $1) } : nil)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: InfoHash.self) { ids in
                    TransferContextMenu(ids: Array(ids))
                } primaryAction: { ids in
                    if let id = ids.first { store.openContent(id) }
                }
                .onDeleteCommand { store.requestRemove() }
                .onKeyPress(.space) {
                    // Space previews the selection with Quick Look, as in Finder.
                    let urls = store.selectedTransfers.compactMap { store.existingContentURL($0.id) }
                    guard let first = urls.first else { return .ignored }
                    quickLookURL = quickLookURL == nil ? first : nil
                    return .handled
                }
                .quickLookPreview($quickLookURL, in: store.selectedTransfers.compactMap { store.existingContentURL($0.id) })
            }
        }
        .navigationTitle(store.filter.title)
        .navigationSubtitle(subtitle)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let magnet = store.clipboardMagnet { ClipboardBanner(magnet: magnet) }
                StatusFooter()
            }
        }
    }

    private var subtitle: String {
        let count = store.transfers.filter(store.filter.matches).count
        return count == 0 ? "No transfers" : "\(count) transfer\(count == 1 ? "" : "s")"
    }
}

/// Sort choices, shared by the toolbar and the View menu.
struct SortMenuContent: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Sort By", selection: $settings.sort) {
            ForEach(TransferSort.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Toggle("Reverse Order", isOn: Binding(get: { !settings.sortAscending }, set: { settings.sortAscending = !$0 }))
    }
}

struct TransferContextMenu: View {
    @Environment(TransferStore.self) private var store
    let ids: [InfoHash]

    var body: some View {
        let items = store.transfers.filter { ids.contains($0.id) }
        if !items.isEmpty {
            let canPause = items.contains { ![.paused, .finished, .error].contains($0.state) }
            Button(canPause ? "Pause" : "Resume", systemImage: canPause ? "pause" : "play") { store.togglePause(ids) }
            Divider()
            Button("Open", systemImage: "arrow.up.forward.app") { ids.forEach(store.openContent) }
                .disabled(!items.contains { $0.completedSize > 0 })
            Button("Show in Finder", systemImage: "folder") { store.reveal(ids) }
            if ids.count == 1 {
                Button("Move Files To…", systemImage: "folder.badge.gearshape") { store.move(ids[0]) }
                    .disabled(!items[0].hasMetadata)
            }
            Divider()
            Button("Copy Magnet Link", systemImage: "link") { store.copyMagnetLinks(ids) }
            if ids.count == 1 {
                Button("Save Torrent File…", systemImage: "square.and.arrow.down") { store.exportTorrentFile(ids[0]) }
                    .disabled(!items[0].hasMetadata)
            }
            Divider()
            Toggle("Download in Order", isOn: Binding(get: { items.allSatisfy(\.isSequential) }, set: { store.setSequential(ids, $0) }))
            Button("Verify Local Data", systemImage: "checkmark.shield") { store.recheck(ids) }
            Button("Ask for More Peers", systemImage: "antenna.radiowaves.left.and.right") { store.reannounce(ids) }
            Menu("Queue") {
                Button("Move to Top") { store.moveToTop(ids) }
                Button("Move to Bottom") { store.moveToBottom(ids) }
            }
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) { store.requestRemove(ids) }
        }
    }
}

struct TransferRow: View {
    let status: TorrentStatus
    @Environment(TransferStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            TransferIcon(status: status, size: 38)
                .overlay(alignment: .bottomTrailing) { stateBadge.offset(x: 4, y: 3) }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(status.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    rates
                }
                TransferProgressBar(progress: status.displayProgress, tint: status.state.tint, animated: status.state == .downloading && status.downloadRate > 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(status.summary)
                        .font(.caption)
                        .foregroundStyle(status.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(status.hasMetadata ? Format.percent(status.displayProgress) : "")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                store.togglePause([status.id])
            } label: {
                Image(systemName: isStopped ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    // Primary and secondary follow the row's selection highlight; an accent colour would vanish into it.
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(isStopped ? "Resume" : "Pause")
            .accessibilityLabel(isStopped ? "Resume" : "Pause")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var isStopped: Bool { [.paused, .finished, .error].contains(status.state) }

    private var stateBadge: some View {
        Image(systemName: status.state.symbol)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(status.state == .queued || status.state == .paused ? Color.gray : status.state.tint, in: Circle())
            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            .opacity(status.state == .seeding || status.isActive || status.state == .error || status.state == .paused ? 1 : 0.9)
    }

    /// Download speed while downloading (even when stalled), upload speed while seeding, and either whenever it's moving.
    @ViewBuilder
    private var rates: some View {
        let showDown = status.state == .downloading || status.downloadRate > 0
        let showUp = status.state == .seeding || status.uploadRate > 0
        if showDown || showUp {
            HStack(spacing: 10) {
                if showDown {
                    Label(status.downloadRate.speed, systemImage: "arrow.down")
                        .foregroundStyle(status.downloadRate > 0 ? Color.accentColor : .secondary)
                }
                if showUp {
                    Label(status.uploadRate.speed, systemImage: "arrow.up")
                        .foregroundStyle(status.uploadRate > 0 ? Color.green : .secondary)
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .fixedSize() // the name truncates first
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.caption2.weight(.bold))
            configuration.title
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Environment(TransferStore.self) private var store

    var body: some View {
        // Scrolls rather than imposing a minimum size, which would fight the window's own limits.
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 22) {
            MurmurationView()
                .frame(width: 420, height: 220)
                .mask(RadialGradient(colors: [.black, .black, .clear], center: .center, startRadius: 40, endRadius: 210))
            VStack(spacing: 8) {
                Text("Nothing Downloading Yet")
                    .font(.title2.weight(.semibold))
                Text("Drop a torrent file here, open a magnet link, or paste one.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    store.presentOpenPanel()
                } label: {
                    Label("Open Torrent File", systemImage: "doc.badge.plus")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                Button {
                    store.presentMagnetSheet()
                } label: {
                    Label("Add Magnet Link", systemImage: "link")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(40)
    }
}

// MARK: - Footer and banners

struct StatusFooter: View {
    @Environment(TransferStore.self) private var store
    @State private var showStatistics = false

    var body: some View {
        let stats = store.stats
        HStack(spacing: 14) {
            Button {
                showStatistics.toggle()
            } label: {
                HStack(spacing: 14) {
                    Label(stats.downloadRate.speed, systemImage: "arrow.down")
                        .foregroundStyle(stats.downloadRate > 0 ? Color.accentColor : .secondary)
                    Label(stats.uploadRate.speed, systemImage: "arrow.up")
                        .foregroundStyle(stats.uploadRate > 0 ? Color.green : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Statistics")
            .popover(isPresented: $showStatistics, arrowEdge: .top) { StatisticsView() }
            // Drop the counts, least useful first, rather than squeezing them into dots.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { Divider().frame(height: 12); peerCount; dhtCount }
                HStack(spacing: 14) { Divider().frame(height: 12); peerCount }
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 8)
            portStatus.layoutPriority(1)
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        // The bar must never ask for more width than the column has: when it did, the split view
        // renegotiated its column widths in a loop until AppKit gave up (a crash in narrow windows).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var peerCount: some View {
        Text("\(store.stats.connectedPeers) peer\(store.stats.connectedPeers == 1 ? "" : "s")").fixedSize()
    }

    @ViewBuilder
    private var dhtCount: some View {
        if store.settings.enableDHT {
            Text("DHT \(store.stats.dhtNodes) node\(store.stats.dhtNodes == 1 ? "" : "s")").fixedSize()
        }
    }

    @ViewBuilder
    private var portStatus: some View {
        let stats = store.stats
        let reachable = stats.incomingConnections > 0 || stats.portMapping == "NAT-PMP" || stats.portMapping == "UPnP"
        HStack(spacing: 5) {
            Circle()
                .fill(stats.portMapping?.hasPrefix("Waiting") == true ? .red : (reachable ? .green : (stats.isListening ? .yellow : .gray)))
                .frame(width: 7, height: 7)
            Text(portText)
        }
        .help(reachable ? "Peers can connect to you." : "Peers may not be able to connect to you. Turn on port mapping or forward the port on your router.")
    }

    private var portText: String {
        let stats = store.stats
        if let mapping = stats.portMapping, mapping.hasPrefix("Waiting") { return mapping }
        if !stats.isListening { return "Not listening" }
        var text = "Port \(stats.listenPort)"
        if let mapping = stats.portMapping { text += " · \(mapping)" }
        return text
    }
}

private struct ClipboardBanner: View {
    @Environment(TransferStore.self) private var store
    let magnet: MagnetLink

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.circle.fill")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Magnet link on the clipboard")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(magnet.displayName ?? magnet.infoHash.hex)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Add") { store.addMagnet(magnet.uri) }
                .buttonStyle(.glassProminent)
            Button {
                withAnimation(.snappy) { store.clipboardMagnet = nil }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 0, maxWidth: .infinity) // see StatusFooter: never wider than the column
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Totals for this session and across every launch.
struct StatisticsView: View {
    @Environment(TransferStore.self) private var store

    var body: some View {
        let stats = store.stats
        let settings = store.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Statistics").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("This session").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("All time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                GridRow {
                    Label("Downloaded", systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                    Text(stats.sessionDownloaded.bytes)
                    Text(settings.allTimeDownloaded.bytes)
                }
                GridRow {
                    Label("Uploaded", systemImage: "arrow.up").foregroundStyle(.green)
                    Text(stats.sessionUploaded.bytes)
                    Text(settings.allTimeUploaded.bytes)
                }
                GridRow {
                    Label("Ratio", systemImage: "arrow.up.arrow.down").foregroundStyle(.secondary)
                    Text(ratio(stats.sessionUploaded, stats.sessionDownloaded))
                    Text(ratio(settings.allTimeUploaded, settings.allTimeDownloaded))
                }
                GridRow {
                    Label("Time", systemImage: "clock").foregroundStyle(.secondary)
                    Text(store.launchDate, style: .relative)
                    Text("since \(settings.firstLaunch.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .font(.callout)
            .monospacedDigit()
            Divider()
            HStack(spacing: 16) {
                Label("\(store.transfers.count) transfers", systemImage: "tray.full")
                Label("\(stats.connectedPeers) peers", systemImage: "person.2")
                Label("\(stats.incomingConnections) incoming", systemImage: "arrow.down.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func ratio(_ up: Int64, _ down: Int64) -> String {
        down > 0 ? Format.ratio(Double(up) / Double(down)) : "–"
    }
}
