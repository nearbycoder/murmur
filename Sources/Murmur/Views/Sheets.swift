import MurmurKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add magnet link

struct AddMagnetSheet: View {
    @Environment(TransferStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Magnet Link").font(.title3.weight(.semibold))
                    Text("Paste a magnet link or an info hash.").foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $store.magnetDraft)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 96)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if store.magnetDraft.isEmpty {
                        Text("magnet:?xt=urn:btih:…")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(13)
                            .allowsHitTesting(false)
                    }
                }
            if let link = parsed {
                Label(link.displayName ?? link.infoHash.hex, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if store.addMagnet(store.magnetDraft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var parsed: MagnetLink? {
        let text = store.magnetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? MagnetLink(text)) ?? MagnetLink.find(in: text)
    }
}

// MARK: - Add torrent file (choose files and location)

struct AddTorrentSheet: View {
    @Environment(TransferStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pending: PendingTorrent
    @State private var priorities: [Int: FilePriority] = [:]
    @State private var folder: URL
    @State private var start: Bool

    init(pending: PendingTorrent) {
        self.pending = pending
        _folder = State(initialValue: AppSettings.shared.downloadFolder)
        _start = State(initialValue: AppSettings.shared.startTransfersAutomatically)
    }

    private var info: TorrentInfo { pending.meta.info }
    private var files: [(id: Int, file: TorrentFileEntry)] {
        info.files.enumerated().filter { !$0.element.isPadding }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: info.isMultiFile ? FileIcons.icon(forExtension: "/folder") : FileIcons.icon(forExtension: (info.name as NSString).pathExtension.lowercased()))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(info.totalLength.bytes) · \(files.count) file\(files.count == 1 ? "" : "s")\(info.isPrivate ? " · Private" : "")")
                        .foregroundStyle(.secondary)
                    if let comment = pending.meta.comment, !comment.isEmpty {
                        Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(20)

            if files.count > 1 {
                FileTreeList(nodes: FileNode.tree(files.map { ($0.id, $0.file.relativePath, $0.file.length, 0) }),
                             priorities: priorities, showsProgress: false) { ids, priority in
                    for id in ids { priorities[id] = priority }
                }
                .frame(minHeight: 220, maxHeight: 360)
                HStack {
                    Text("\(selectedCount) of \(files.count) selected · \(selectedSize.bytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") { priorities = [:] }
                    Button("Select None") { for f in files { priorities[f.id] = .skip } }
                }
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
            }

            Form {
                LabeledContent("Save to") {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Start downloading right away", isOn: $start)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(selectedCount == 0)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560)
    }

    private var selectedCount: Int { files.filter { (priorities[$0.id] ?? .normal) != .skip }.count }
    private var selectedSize: Int64 { files.filter { (priorities[$0.id] ?? .normal) != .skip }.reduce(0) { $0 + $1.file.length } }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func add() {
        let list = info.files.indices.map { priorities[$0] ?? .normal }
        do {
            try store.commit(data: pending.data, folder: folder, priorities: list, start: start)
            dismiss()
        } catch {
            dismiss()
            store.alert = AlertItem(title: "Couldn't Add Torrent", message: error.localizedDescription)
        }
    }
}

// MARK: - Create a torrent

struct CreateTorrentSheet: View {
    @Environment(TransferStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var trackers = "udp://tracker.opentrackr.org:1337/announce\nudp://open.demonii.com:1337/announce\nudp://tracker.openbittorrent.com:6969/announce"
    @State private var comment = ""
    @State private var isPrivate = false
    @State private var seed = true
    @State private var progress: Double?
    @State private var error: String?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Torrent").font(.title3.weight(.semibold))

            Button(action: chooseSource) {
                HStack(spacing: 12) {
                    if let source {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: source.path)).resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading) {
                            Text(source.lastPathComponent).font(.headline)
                            Text((source.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Change…").foregroundStyle(.tint)
                    } else {
                        Image(systemName: "plus.rectangle.on.folder").font(.system(size: 26)).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("Choose a File or Folder").font(.headline)
                            Text("Or drop it here").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in source = url } }
                }
                return true
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Trackers").font(.callout.weight(.medium))
                TextEditor(text: $trackers)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 70)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("One per line. Leave empty for a trackerless torrent that relies on the DHT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Comment (optional)", text: $comment)
            HStack(spacing: 20) {
                Toggle("Private torrent", isOn: $isPrivate)
                    .help("Private torrents only use their trackers: no DHT or peer exchange.")
                Toggle("Start seeding", isOn: $seed)
            }

            if let progress {
                ProgressView(value: progress) { Text("Hashing…").font(.caption) }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(source == nil || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { source = panel.url }
    }

    private func create() {
        guard let source else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "\(source.lastPathComponent).torrent"
        save.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        guard save.runModal() == .OK, let destination = save.url else { return }
        var options = TorrentCreator.Options()
        options.trackers = trackers.split(whereSeparator: \.isNewline).map { [$0.trimmingCharacters(in: .whitespaces)] }.filter { !$0[0].isEmpty }
        options.comment = comment.isEmpty ? nil : comment
        options.isPrivate = isPrivate
        progress = 0
        error = nil
        let shouldSeed = seed
        Task.detached(priority: .userInitiated) {
            do {
                let data = try TorrentCreator.create(from: source, options: options) { value in
                    Task { @MainActor in progress = value }
                }
                try data.write(to: destination)
                await MainActor.run {
                    if shouldSeed {
                        try? store.commit(data: data, folder: source.deletingLastPathComponent(), priorities: nil, start: true)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    progress = nil
                }
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let onFinish: () -> Void
    @Bindable private var settings = AppSettings.shared
    @State private var isDefault = DefaultApp.isDefault

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MurmurationView(count: 160)
                    .frame(height: 150)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            }
            .padding(.top, 18)
            Text("Welcome to Murmur")
                .font(.title.weight(.semibold))
            Text("A fast, private torrent client that feels at home on your Mac.")
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Form {
                LabeledContent {
                    Button("Choose…") { chooseFolder() }
                } label: {
                    Text("Downloads go to")
                    Text((settings.downloadFolder.path as NSString).abbreviatingWithTildeInPath)
                }
                LabeledContent {
                    if isDefault {
                        Label("Default", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            Task {
                                await DefaultApp.makeDefault()
                                isDefault = DefaultApp.isDefault
                            }
                        }
                    }
                } label: {
                    Text("Open magnet links and torrents")
                    Text("Click a magnet link in your browser to start it in Murmur.")
                }
                Toggle(isOn: $settings.notifyOnCompletion) {
                    Text("Notify me when downloads finish")
                }
                .onChange(of: settings.notifyOnCompletion) { _, on in if on { Notifier.shared.requestAuthorization() } }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                if settings.notifyOnCompletion { Notifier.shared.requestAuthorization() }
                onFinish()
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url }
    }
}
