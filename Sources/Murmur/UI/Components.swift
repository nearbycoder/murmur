import Charts
import MurmurKit
import SwiftUI

/// A slim capsule progress bar tinted by transfer state.
struct TransferProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 6
    var animated = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(progress > 0 ? height : 0, geo.size.width * min(max(progress, 0), 1)))
                    .overlay {
                        if animated { Shimmer().clipShape(Capsule()) }
                    }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Format.percent(progress))
    }
}

/// A soft highlight that sweeps across active progress bars.
private struct Shimmer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            GeometryReader { geo in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(geo.size.width * 0.35, 30))
                    .offset(x: (geo.size.width * 1.4) * t - geo.size.width * 0.35)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Download and upload speed over the last two minutes.
struct SpeedChart: View {
    let samples: [SpeedSample]
    var showsAxis = true

    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.id), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.id), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.id), y: .value("Speed", s.up), series: .value("Direction", "Upload"))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: (samples.last?.id ?? 120) - 119 ... max(samples.last?.id ?? 120, 1))
        .chartYAxis {
            if showsAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(v.speed).font(.caption2) } }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 0)) { _ in }
            }
        }
        .chartYScale(domain: 0 ... max(samples.map { max($0.down, $0.up) }.max() ?? 0, 64 * 1024) * 1.15)
        .chartLegend(.hidden)
        .animation(.linear(duration: 0.9), value: samples.last?.id)
    }
}

/// Which parts of the torrent are downloaded, drawn as a strip.
struct PieceMap: View {
    let values: [Float]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let width = size.width / CGFloat(values.count)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.14)))
            for (i, v) in values.enumerated() where v > 0 {
                let rect = CGRect(x: CGFloat(i) * width, y: 0, width: width + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(tint.opacity(v >= 1 ? 1 : 0.25 + Double(v) * 0.6)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityLabel("Piece map")
    }
}

/// A flock of dots wheeling in slow figure eights: the empty state, and Murmur's namesake.
struct MurmurationView: View {
    var count = 300
    var colors: [Color] = [Color(red: 0.38, green: 0.32, blue: 0.92), Color(red: 0.96, green: 0.45, blue: 0.42)]

    private struct Bird {
        let u: Double
        let spread: Double
        let angle: Double
        let size: Double
        let drift: Double
    }

    private let birds: [Bird] = {
        var generator = SeededGenerator(seed: 42)
        return (0..<320).map { _ in
            Bird(u: Double.random(in: 0...1, using: &generator),
                 spread: pow(Double.random(in: 0...1, using: &generator), 2),
                 angle: Double.random(in: 0...(2 * .pi), using: &generator),
                 size: Double.random(in: 2.2...4.6, using: &generator),
                 drift: Double.random(in: 0.6...1.4, using: &generator))
        }
    }()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate * 0.35
                let cx = size.width / 2, cy = size.height / 2
                let a = size.width * 0.36, b = size.height * 0.28
                for bird in birds.prefix(count) {
                    // Each bird rides a morphing figure-eight, offset a little from the flock's spine.
                    let s = bird.u * 2 * .pi + t * 0.6
                    let wobble = sin(t * 0.7 + bird.u * 6) * 0.25
                    let x = cx + a * sin(s) * (1 + 0.18 * sin(t * 0.43))
                    let y = cy + b * sin(2 * s + wobble) * 0.55 + b * 0.25 * cos(s + t * 0.31)
                    let r = (6 + 34 * bird.spread) * (1 + 0.3 * sin(t * bird.drift + bird.angle))
                    let px = x + r * cos(bird.angle + t * bird.drift)
                    let py = y + r * sin(bird.angle + t * bird.drift) * 0.6
                    let mix = (sin(s) + 1) / 2
                    let color = mix < 0.5 ? colors[0] : colors[1]
                    let opacity = 0.55 + 0.45 * (1 - bird.spread)
                    let d = bird.size
                    canvas.fill(Path(ellipseIn: CGRect(x: px - d / 2, y: py - d / 2, width: d, height: d)), with: .color(color.opacity(opacity)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The icon shown for a transfer: the file type's icon, or a symbol while there's no file list.
struct TransferIcon: View {
    let status: TorrentStatus
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = FileIcons.icon(for: status) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "link.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A small label/value pair used throughout the inspector.
struct InfoRow: View {
    let label: String
    let value: String
    var selectable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Group {
                if selectable { Text(value).textSelection(.enabled) } else { Text(value) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(selectable ? 3 : 1)
            .truncationMode(.middle)
        }
        .font(.callout)
    }
}

/// A rounded section used to group inspector content.
struct InspectorCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
