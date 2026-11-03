import AppKit
import MurmurKit
import SwiftUI
import UniformTypeIdentifiers

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
    return f
}()

extension Int64 {
    var bytes: String { byteFormatter.string(fromByteCount: self) }
    var speed: String { self <= 0 ? "0 KB/s" : "\(byteFormatter.string(fromByteCount: self))/s" }
}

extension Double {
    var bytes: String { Int64(self).bytes }
    var speed: String { Int64(self).speed }
}

enum Format {
    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.day, .hour, .minute, .second]
        return f
    }()

    static func eta(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds > 60 * 60 * 24 * 30 { return "a long time" }
        return etaFormatter.string(from: seconds.rounded())
    }

    static func ratio(_ value: Double) -> String { String(format: "%.2f", value) }

    static func percent(_ value: Double) -> String {
        value >= 1 ? "100%" : String(format: value < 0.1 ? "%.1f%%" : "%.0f%%", value * 100)
    }
}

extension TorrentState {
    var title: String {
        switch self {
        case .fetchingMetadata: "Finding peers"
        case .checking: "Verifying"
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .paused: "Paused"
        case .finished: "Finished"
        case .error: "Error"
        }
    }

    var tint: Color {
        switch self {
        case .downloading: .accentColor
        case .fetchingMetadata: .purple
        case .seeding: .green
        case .checking: .orange
        case .queued: .secondary
        case .paused: .secondary
        case .finished: .teal
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .downloading: "arrow.down"
        case .fetchingMetadata: "magnifyingglass"
        case .seeding: "arrow.up"
        case .checking: "checkmark.shield"
        case .queued: "clock"
        case .paused: "pause.fill"
        case .finished: "checkmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

extension FilePriority {
    var title: String {
        switch self {
        case .skip: "Don't Download"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

extension TorrentStatus {
    /// "1.2 GB of 4.7 GB · 12 peers · 4 min left", the line under the name.
    var summary: String {
        switch state {
        case .fetchingMetadata:
            return connectedPeers > 0 ? "Getting file list from \(connectedPeers) peer\(connectedPeers == 1 ? "" : "s")…" : "Looking for peers…"
        case .checking:
            return "Verifying local data… \(Format.percent(checkingProgress ?? 0))"
        case .downloading:
            var parts = ["\(completedSize.bytes) of \(wantedSize.bytes)"]
            parts.append("\(connectedPeers) peer\(connectedPeers == 1 ? "" : "s")")
            if let eta = Format.eta(eta) { parts.append("\(eta) left") } else if downloadRate == 0 { parts.append(connectedPeers == 0 ? "connecting" : "stalled") }
            return parts.joined(separator: " · ")
        case .seeding:
            return "\(wantedSize.bytes) · ratio \(Format.ratio(ratio)) · \(connectedPeers) peer\(connectedPeers == 1 ? "" : "s")"
        case .queued:
            return isComplete ? "Queued to seed" : "Queued · \(completedSize.bytes) of \(wantedSize.bytes)"
        case .paused:
            return hasMetadata ? "Paused · \(completedSize.bytes) of \(wantedSize.bytes)" : "Paused"
        case .finished:
            return "\(wantedSize.bytes) · ratio \(Format.ratio(ratio))"
        case .error:
            return errorMessage ?? "Error"
        }
    }

    var displayProgress: Double {
        if state == .checking { return checkingProgress ?? 0 }
        return progress
    }
}

/// File-type icons from the system, cached by extension.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for status: TorrentStatus) -> NSImage? {
        guard status.hasMetadata else { return nil }
        if status.isMultiFile { return icon(forExtension: "/folder") }
        return icon(forExtension: status.primaryFileExtension ?? "")
    }

    static func icon(forExtension ext: String) -> NSImage {
        if let cached = cache[ext] { return cached }
        let image: NSImage
        if ext == "/folder" {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        cache[ext] = image
        return image
    }
}
