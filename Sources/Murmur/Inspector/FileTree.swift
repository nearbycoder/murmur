import MurmurKit
import SwiftUI

/// A folder or file in a torrent's file list, with totals rolled up into folders.
struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    /// File indices in the torrent covered by this node.
    let fileIDs: [Int]
    let length: Int64
    let downloaded: Int64
    var children: [FileNode]?

    var isFolder: Bool { children != nil }
    var progress: Double { length == 0 ? 1 : Double(downloaded) / Double(length) }

    /// Builds a tree from slash-separated paths, folders first and sorted naturally.
    static func tree(_ files: [(id: Int, path: String, length: Int64, downloaded: Int64)]) -> [FileNode] {
        final class Builder {
            var folders: [String: Builder] = [:]
            var files: [FileNode] = []
        }
        let root = Builder()
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            var node = root
            for part in parts.dropLast() {
                if node.folders[part] == nil { node.folders[part] = Builder() }
                node = node.folders[part]!
            }
            node.files.append(FileNode(id: "f\(file.id)", name: parts.last ?? file.path, fileIDs: [file.id], length: file.length, downloaded: file.downloaded, children: nil))
        }
        func build(_ builder: Builder, path: String) -> [FileNode] {
            let folders = builder.folders.map { name, child -> FileNode in
                let kids = build(child, path: path + "/" + name)
                return FileNode(id: "d" + path + "/" + name, name: name, fileIDs: kids.flatMap(\.fileIDs),
                                length: kids.reduce(0) { $0 + $1.length }, downloaded: kids.reduce(0) { $0 + $1.downloaded }, children: kids)
            }
            let sort: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders.sorted(by: sort) + builder.files.sorted(by: sort)
        }
        return build(root, path: "")
    }
}

/// A checkbox that shows a dash when only some files in a folder are selected.
struct TriStateCheckbox: View {
    enum Value { case on, off, mixed }
    let value: Value
    let action: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { value == .on }, set: { action($0) })) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .overlay {
                if value == .mixed {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .overlay(Capsule().fill(.white).frame(width: 8, height: 2))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The file list with selection checkboxes, used in the inspector and the add sheet.
struct FileTreeList: View {
    let nodes: [FileNode]
    let priorities: [Int: FilePriority]
    var showsProgress = true
    let setPriority: ([Int], FilePriority) -> Void
    var reveal: ((FileNode) -> Void)?
    /// Quick Look and open, for files that are on disk.
    var preview: ((FileNode) -> Void)?
    var open: ((FileNode) -> Void)?

    var body: some View {
        List {
            OutlineGroup(nodes, children: \.children) { node in
                FileRow(node: node, state: state(of: node), priority: priority(of: node), showsProgress: showsProgress) { selected in
                    setPriority(node.fileIDs, selected ? .normal : .skip)
                }
                .contextMenu {
                    ForEach([FilePriority.high, .normal, .low, .skip]) { p in
                        Button(p.title) { setPriority(node.fileIDs, p) }
                    }
                    if !node.isFolder, let preview, let open {
                        Divider()
                        Button("Quick Look") { preview(node) }
                        Button("Open") { open(node) }
                    }
                    if let reveal {
                        Divider()
                        Button("Show in Finder") { reveal(node) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func state(of node: FileNode) -> TriStateCheckbox.Value {
        let selected = node.fileIDs.filter { (priorities[$0] ?? .normal) != .skip }.count
        if selected == 0 { return .off }
        return selected == node.fileIDs.count ? .on : .mixed
    }

    private func priority(of node: FileNode) -> FilePriority? {
        let set = Set(node.fileIDs.map { priorities[$0] ?? .normal })
        return set.count == 1 ? set.first : nil
    }
}

private struct FileRow: View {
    let node: FileNode
    let state: TriStateCheckbox.Value
    let priority: FilePriority?
    let showsProgress: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(value: state, action: toggle)
            Image(nsImage: node.isFolder ? FileIcons.icon(forExtension: "/folder") : FileIcons.icon(forExtension: (node.name as NSString).pathExtension.lowercased()))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(state == .off ? .secondary : .primary)
                    if priority == .high { Image(systemName: "arrow.up").font(.caption2.bold()).foregroundStyle(.orange).help("High priority") }
                    if priority == .low { Image(systemName: "arrow.down").font(.caption2.bold()).foregroundStyle(.secondary).help("Low priority") }
                }
                if showsProgress && state != .off {
                    TransferProgressBar(progress: node.progress, tint: node.progress >= 1 ? .green : .accentColor, height: 3)
                }
            }
            Spacer(minLength: 6)
            Text(node.length.bytes)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
