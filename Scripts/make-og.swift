// Renders the social card (docs/assets/og.png, 1200×630) and the README banner (assets/banner.png).
// Usage: swift Scripts/make-og.swift   (after Scripts/shoot.sh and Scripts/render-icon.swift)
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let icon = NSImage(contentsOfFile: "docs/assets/icon-1024.png")!
let shot = NSImage(contentsOfFile: "docs/screenshots/overview-dark.png")!

func render(width: Int, height: Int, to path: String) {
    let size = NSSize(width: width, height: height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSGradient(colors: [color(0x241F5E), color(0x4B3488), color(0xB4527A)])!.draw(in: NSRect(origin: .zero, size: size), angle: -60)

    // A faint flock drifting across the background.
    var seed: UInt64 = 3
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 11) / CGFloat(1 << 53) }
    for i in 0..<260 {
        let t = CGFloat(i) / 260
        let x = size.width * (0.05 + 0.9 * t)
        let y = size.height * (0.82 - 0.35 * sin(t * .pi * 1.2)) + (rnd() - 0.5) * 70 * (1 - abs(t - 0.5))
        let d = 1.5 + rnd() * 3
        color(0xFFFFFF, 0.08 + rnd() * 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
    }

    let scale = CGFloat(height) / 630
    // Screenshot, tilted out of frame on the right.
    let shotWidth = 760 * scale
    let shotHeight = shotWidth * shot.size.height / shot.size.width
    let shotRect = NSRect(x: size.width - shotWidth * 0.86, y: (size.height - shotHeight) / 2 - 10 * scale, width: shotWidth, height: shotHeight)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 40 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
    shadow.set()
    NSBezierPath(roundedRect: shotRect, xRadius: 14 * scale, yRadius: 14 * scale).addClip()
    shot.draw(in: shotRect)
    NSGraphicsContext.restoreGraphicsState()

    // Icon and words on the left.
    let left = 72 * scale
    icon.draw(in: NSRect(x: left - 14 * scale, y: size.height - 250 * scale, width: 170 * scale, height: 170 * scale))
    let title = NSAttributedString(string: "Murmur", attributes: [
        .font: NSFont.systemFont(ofSize: 76 * scale, weight: .bold), .foregroundColor: NSColor.white, .kern: -1.5 * scale,
    ])
    title.draw(at: NSPoint(x: left, y: size.height - 350 * scale))
    let lines = ["A native torrent client", "for macOS. Free and", "open source."]
    for (i, line) in lines.enumerated() {
        NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: 30 * scale, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.82),
        ]).draw(at: NSPoint(x: left, y: size.height - (400 + CGFloat(i) * 40) * scale))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

render(width: 1200, height: 630, to: "docs/assets/og.png")
render(width: 1280, height: 640, to: "assets/banner.png")
