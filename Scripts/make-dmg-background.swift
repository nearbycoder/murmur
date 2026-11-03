// Renders the installer window background: Resources/dmg/background.tiff (1x + 2x).
// Usage: swift Scripts/make-dmg-background.swift
// The flock arcs between icon_locations in Resources/dmg/settings.py: (160, 186) and (480, 186).
import AppKit

let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 160, y: size.height - 186)
let applicationsCenter = NSPoint(x: 480, y: size.height - 186)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A tiny deterministic generator so the flock looks the same every render.
struct Seeded {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

func draw() {
    // Dusk: the same indigo-to-coral as the app icon, deepened so white labels stay legible.
    NSGradient(colors: [color(0x2A2470), color(0x5A3A8C), color(0x9C4E7A)])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // A murmuration streaming from the app to Applications, thick at the start and thinning out.
    var random = Seeded(state: 7)
    let from = NSPoint(x: appCenter.x + 84, y: appCenter.y + 6)
    let to = NSPoint(x: applicationsCenter.x - 84, y: applicationsCenter.y + 6)
    let control = NSPoint(x: (from.x + to.x) / 2, y: appCenter.y + 70)
    for i in 0..<150 {
        let t = Double(i) / 149
        let x = pow(1 - t, 2) * from.x + 2 * (1 - t) * t * control.x + pow(t, 2) * to.x
        let y = pow(1 - t, 2) * from.y + 2 * (1 - t) * t * control.y + pow(t, 2) * to.y
        let spread = 16 * (1 - t) + 3
        let px = x + (random.next() - 0.5) * spread * 1.6
        let py = y + (random.next() - 0.5) * spread
        let d = (3.2 - 1.8 * t) * (0.6 + 0.4 * random.next())
        color(0xFFFFFF, 0.35 + 0.5 * random.next()).setFill()
        NSBezierPath(ovalIn: NSRect(x: px - d / 2, y: py - d / 2, width: d, height: d)).fill()
    }
    // Arrowhead where the flock lands.
    color(0xFFFFFF, 0.85).setStroke()
    let head = NSBezierPath()
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: to.x - 11, y: to.y + 9))
    head.line(to: NSPoint(x: to.x, y: to.y))
    head.line(to: NSPoint(x: to.x - 13, y: to.y - 4))
    head.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(string: "Drag Murmur into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: 0, y: 64, width: size.width, height: 24))
    NSAttributedString(string: "Then open a magnet link or a .torrent file", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: 0, y: 44, width: size.width, height: 20))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let output = URL(fileURLWithPath: "Resources/dmg/background.tiff")
try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: output)
print("Wrote \(output.path)")
