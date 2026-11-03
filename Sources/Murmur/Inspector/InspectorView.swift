import MurmurKit
import QuickLook
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview, files, peers, trackers
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct InspectorView: View {
    @Environment(TransferStore.self) private var store
    @AppStorage("inspectorTab") private var tab: InspectorTab = .overview

    var body: some View {
        Group {
            if let status = store.selectedTransfer {
                VStack(spacing: 0) {
                    InspectorHeader(status: status)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    Picker("Section", selection: $tab) {
                        ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    content(status)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else if store.selection.count > 1 {
                MultipleSelectionView(transfers: store.selectedTransfers)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a transfer to see its files, peers and trackers."))
            }
        }
    }

    @ViewBuilder
    private func content(_ status: TorrentStatus) -> some View {
        switch tab {
        case .overview: OverviewTab(status: status, details: store.details)
        case .files: FilesTab(status: status, details: store.details)
        case .peers: PeersTab(details: store.details)
        case .trackers: TrackersTab(status: status, details: store.details)
        }
    }
}

private struct InspectorHeader: View {
    let status: TorrentStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TransferIcon(status: status, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.name)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Label(status.state.title, systemImage: status.state.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(status.state == .paused || status.state == .queued ? Color.secondary : status.state.tint)
                        .background((status.state == .paused || status.state == .queued ? Color.secondary : status.state.tint).opacity(0.14), in: Capsule())
                    if status.isPrivate {
                        Label("Private", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @Environment(TransferStore.self) private var store
    let status: TorrentStatus
    let details: TorrentDetails?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                InspectorCard {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.percent(status.displayProgress))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(status.hasMetadata ? "\(status.completedSize.bytes) of \(status.wantedSize.bytes)" : "Waiting for file list")
                                .font(.callout.weight(.medium))
                            if let eta = Format.eta(status.eta) {
                                Text("\(eta) remaining").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let details, !details.pieceMap.isEmpty {
                        PieceMap(values: details.pieceMap, tint: status.isComplete ? .green : .accentColor)
                            .frame(height: 16)
                        Text("\(details.pieceCount.formatted()) pieces of \(Int64(details.pieceLength).bytes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TransferProgressBar(progress: status.displayProgress, tint: status.state.tint)
                    }
                }

                InspectorCard("Speed") {
                    HStack(spacing: 18) {
                        stat("Download", status.downloadRate.speed, .accentColor, "arrow.down")
                        stat("Upload", status.uploadRate.speed, .green, "arrow.up")
                    }
                    SpeedChart(samples: store.transferHistory[status.id] ?? [])
                        .frame(height: 96)
                }

                InspectorCard("Transfer") {
                    InfoRow(label: "Downloaded", value: status.downloaded.bytes)
                    InfoRow(label: "Uploaded", value: status.uploaded.bytes)
                    InfoRow(label: "Ratio", value: Format.ratio(status.ratio))
                    InfoRow(label: "Peers", value: "\(status.connectedPeers) connected · \(status.knownPeers) known")
                    if status.swarmSeeders != nil || status.swarmLeechers != nil {
                        InfoRow(label: "Swarm", value: "\((status.swarmSeeders ?? 0).formatted()) seeds · \((status.swarmLeechers ?? 0).formatted()) leechers")
                    }
                }

                InspectorCard("Options") {
                    Toggle("Download in order", isOn: Binding(get: { status.isSequential }, set: { store.setSequential([status.id], $0) }))
                        .help("Fetch pieces from start to end, so media can be previewed while downloading")
                    TransferLimitRow(title: "Limit download", value: status.downloadLimit) { store.setSpeedLimits([status.id], download: $0, upload: nil) }
                    TransferLimitRow(title: "Limit upload", value: status.uploadLimit) { store.setSpeedLimits([status.id], download: nil, upload: $0) }
                    HStack {
                        Text("Seeding")
                        Spacer()
                        RatioMenu(status: status)
                    }
                    HStack {
                        Button("Copy Magnet Link", systemImage: "link") { store.copyMagnetLinks([status.id]) }
                        Button("Verify", systemImage: "checkmark.shield") { store.recheck([status.id]) }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                InspectorCard("Details") {
                    if status.hasMetadata {
                        InfoRow(label: "Size", value: "\(status.totalSize.bytes) · \(status.fileCount) file\(status.fileCount == 1 ? "" : "s")")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Location").foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                        Button {
                            store.reveal([status.id])
                        } label: {
                            Text((status.savePath.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    InfoRow(label: "Added", value: status.addedDate.formatted(date: .abbreviated, time: .shortened))
                    if let completed = status.completedDate {
                        InfoRow(label: "Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                    }
                    InfoRow(label: "Info hash", value: status.id.hex, selectable: true)
                    if let comment = details?.comment, !comment.isEmpty {
                        InfoRow(label: "Comment", value: comment, selectable: true)
                    }
                    if let createdBy = details?.createdBy {
                        InfoRow(label: "Created by", value: createdBy)
                    }
                    if let created = details?.creationDate {
                        InfoRow(label: "Created", value: created.formatted(date: .abbreviated, time: .omitted))
                    }
                }

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func stat(_ title: String, _ value: String, _ tint: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// A per-transfer speed limit: a checkbox and a KB/s field.
private struct TransferLimitRow: View {
    let title: String
    let value: Int
    let set: (Int) -> Void
    @State private var draft = 500

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value > 0 }, set: { set($0 ? max(draft, 1) * 1024 : 0) }))
            Spacer()
            TextField("KB/s", value: Binding(get: { value > 0 ? value / 1024 : draft }, set: { new in
                draft = max(new, 1)
                if value > 0 { set(draft * 1024) }
            }), format: .number)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .disabled(value == 0)
            Text("KB/s").foregroundStyle(.secondary)
        }
    }
}

private struct RatioMenu: View {
    @Environment(TransferStore.self) private var store
    let status: TorrentStatus

    var body: some View {
        Menu {
            Button("Use Default") { store.setRatioLimit([status.id], nil) }
            Button("Seed Forever") { store.setRatioLimit([status.id], -1) }
            Divider()
            ForEach([0.5, 1, 1.5, 2, 3, 5], id: \.self) { r in
                Button("Stop at \(Format.ratio(r))") { store.setRatioLimit([status.id], r) }
            }
        } label: {
            Text(label)
        }
        .fixedSize()
        .help("When to stop seeding this transfer")
    }

    private var label: String {
        guard let limit = status.ratioLimit else {
            let settings = AppSettings.shared
            return settings.stopAtRatio ? "Default (stop at \(Format.ratio(settings.ratioLimit)))" : "Default (forever)"
        }
        return limit < 0 ? "Seed forever" : "Stop at ratio \(Format.ratio(limit))"
    }
}

// MARK: - Files

private struct FilesTab: View {
    @Environment(TransferStore.self) private var store
    let status: TorrentStatus
    let details: TorrentDetails?
    @State private var previewURL: URL?

    var body: some View {
        if let details, !details.files.isEmpty {
            let nodes = FileNode.tree(details.files.map { ($0.id, $0.path, $0.length, $0.downloaded) })
            let priorities = Dictionary(uniqueKeysWithValues: details.files.map { ($0.id, $0.priority) })
            VStack(spacing: 0) {
                FileTreeList(nodes: nodes, priorities: priorities, setPriority: { ids, priority in
                    store.setFilePriorities(status.id, Dictionary(uniqueKeysWithValues: ids.map { ($0, priority) }))
                }, reveal: { node in
                    reveal(node, details: details)
                }, preview: { node in
                    previewURL = fileURL(node, details: details)
                }, open: { node in
                    if let url = fileURL(node, details: details) { NSWorkspace.shared.open(url) }
                })
                .quickLookPreview($previewURL)
                HStack {
                    let selected = details.files.filter { $0.priority != .skip }
                    Text("\(selected.count) of \(details.files.count) selected · \(selected.reduce(Int64(0)) { $0 + $1.length }.bytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { store.setFilePriorities(status.id, Dictionary(uniqueKeysWithValues: details.files.map { ($0.id, FilePriority.normal) })) }
                    Button("None") { store.setFilePriorities(status.id, Dictionary(uniqueKeysWithValues: details.files.map { ($0.id, FilePriority.skip) })) }
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        } else {
            ContentUnavailableView(status.hasMetadata ? "Loading…" : "Waiting for File List", systemImage: "doc.on.doc", description: Text(status.hasMetadata ? "" : "The files appear once Murmur gets the torrent’s details from a peer."))
        }
    }

    private func fileURL(_ node: FileNode, details: TorrentDetails) -> URL? {
        guard let content = status.contentURL, let id = node.fileIDs.first, let file = details.files.first(where: { $0.id == id }) else { return nil }
        let url = status.isMultiFile ? content.appendingPathComponent(file.path) : content
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func reveal(_ node: FileNode, details: TorrentDetails) {
        guard let content = status.contentURL else { return }
        let urls = node.fileIDs.prefix(50).compactMap { id -> URL? in
            guard let file = details.files.first(where: { $0.id == id }) else { return nil }
            let url = status.isMultiFile ? content.appendingPathComponent(file.path) : content
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [status.savePath] : urls)
    }
}

// MARK: - Peers

private struct PeersTab: View {
    let details: TorrentDetails?

    var body: some View {
        if let peers = details?.peers, !peers.isEmpty {
            List(peers) { peer in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(.quaternary)
                        Circle()
                            .trim(from: 0, to: peer.progress)
                            .stroke(peer.progress >= 1 ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                    .help("Has \(Format.percent(peer.progress))")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.client)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(peer.address.description)
                                .font(.caption.monospaced())
                            if !peer.flags.isEmpty {
                                Text(peer.flags)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    .help(flagHelp(peer))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        if peer.downloadRate > 0 {
                            Label(peer.downloadRate.speed, systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                        }
                        if peer.uploadRate > 0 {
                            Label(peer.uploadRate.speed, systemImage: "arrow.up").foregroundStyle(.green)
                        }
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView("No Peers Connected", systemImage: "person.2", description: Text("Peers appear here as Murmur finds them through trackers, the DHT and other peers."))
        }
    }

    private func flagHelp(_ peer: PeerStatus) -> String {
        var parts: [String] = []
        for c in peer.flags {
            switch c {
            case "D": parts.append("downloading from them")
            case "d": parts.append("want to download, they're choking")
            case "U": parts.append("uploading to them")
            case "u": parts.append("they want data, we're choking")
            case "I": parts.append("incoming connection")
            case "E": parts.append("encrypted")
            case "L": parts.append("found on your local network")
            case "X": parts.append("found through peer exchange")
            case "H": parts.append("found through the DHT")
            case "S": parts.append("snubbed")
            case "O": parts.append("optimistic unchoke")
            default: break
            }
        }
        return parts.joined(separator: ", ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Trackers

private struct TrackersTab: View {
    @Environment(TransferStore.self) private var store
    let status: TorrentStatus
    let details: TorrentDetails?
    @State private var adding = false
    @State private var newTrackers = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !status.isPrivate {
                    sourceRow("DHT", enabled: store.settings.enableDHT, detail: "\(store.stats.dhtNodes) nodes")
                    sourceRow("Peer Exchange", enabled: store.settings.enablePEX, detail: "Learns peers from peers")
                    sourceRow("Local Discovery", enabled: store.settings.enableLocalDiscovery, detail: "Peers on your network")
                }
                ForEach(details?.webSeedStatuses ?? []) { seed in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Circle().fill(seed.status == "Not working" ? Color.red : (seed.status == "Retrying" ? .orange : .green)).frame(width: 8, height: 8)
                            Label(URLComponents(string: seed.url)?.host ?? seed.url, systemImage: "globe")
                                .labelStyle(CompactLabelStyle())
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .help(seed.url)
                            Spacer()
                            if seed.downloadRate > 0 {
                                Text(seed.downloadRate.speed).font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                            }
                        }
                        Text("Web seed · \(seed.message.map { "\(seed.status): \($0)" } ?? seed.status) · \(seed.downloaded.bytes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.leading, 18)
                    }
                    .padding(.vertical, 2)
                }
                ForEach(details?.trackers ?? []) { tracker in
                    TrackerRow(tracker: tracker)
                        .contextMenu {
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tracker.url, forType: .string)
                            }
                            Button("Remove", role: .destructive) { store.removeTracker(status.id, tracker.url) }
                        }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Add Trackers…", systemImage: "plus") { adding = true }
                    .popover(isPresented: $adding) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("One tracker URL per line").font(.callout.weight(.medium))
                            TextEditor(text: $newTrackers)
                                .font(.callout.monospaced())
                                .frame(width: 340, height: 120)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                            HStack {
                                Spacer()
                                Button("Cancel") { adding = false }
                                Button("Add") {
                                    store.addTrackers(status.id, newTrackers)
                                    newTrackers = ""
                                    adding = false
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(newTrackers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(14)
                    }
                Spacer()
                Button("Ask for More Peers", systemImage: "antenna.radiowaves.left.and.right") { store.reannounce([status.id]) }
                    .disabled(!status.isActive)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func sourceRow(_ name: String, enabled: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(enabled ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(name).font(.callout.weight(.medium))
            Spacer()
            Text(enabled ? detail : "Off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrackerRow: View {
    let tracker: TrackerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(host)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tracker.url)
                Spacer()
                if let seeders = tracker.seeders, let leechers = tracker.leechers {
                    Text("\(seeders.formatted()) seeds · \(leechers.formatted()) leechers")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(seeders.formatted()) with the whole thing, \(leechers.formatted()) still downloading")
                }
            }
            HStack(spacing: 6) {
                Text(tracker.message.map { "\(tracker.status): \($0)" } ?? tracker.status)
                    .lineLimit(2)
                Spacer()
                if let next = tracker.nextAnnounce, next > .now {
                    Text("next \(next, style: .relative)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        }
        .padding(.vertical, 2)
    }

    private var host: String { URLComponents(string: tracker.url)?.host ?? tracker.url }

    private var color: Color {
        switch tracker.status {
        case "Working": .green
        case "Announcing…": .orange
        case "Not working": .red
        default: .gray
        }
    }
}

// MARK: - Multiple selection

private struct MultipleSelectionView: View {
    @Environment(TransferStore.self) private var store
    let transfers: [TorrentStatus]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(transfers.prefix(3).enumerated()), id: \.element.id) { index, t in
                    TransferIcon(status: t, size: 56)
                        .rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 18)
                }
            }
            .frame(height: 70)
            Text("\(transfers.count) Transfers Selected")
                .font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                InfoRow(label: "Size", value: transfers.reduce(Int64(0)) { $0 + $1.totalSize }.bytes)
                InfoRow(label: "Downloaded", value: transfers.reduce(Int64(0)) { $0 + $1.downloaded }.bytes)
                InfoRow(label: "Uploaded", value: transfers.reduce(Int64(0)) { $0 + $1.uploaded }.bytes)
                InfoRow(label: "Speed", value: "↓ \(transfers.reduce(Int64(0)) { $0 + $1.downloadRate }.speed)  ↑ \(transfers.reduce(Int64(0)) { $0 + $1.uploadRate }.speed)")
            }
            .padding(.horizontal, 20)
            HStack {
                Button("Pause", systemImage: "pause.fill") { store.pause() }
                Button("Resume", systemImage: "play.fill") { store.resume() }
            }
            .buttonStyle(.glass)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
