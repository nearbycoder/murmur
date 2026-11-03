// Exports the app icon, as macOS renders it (Liquid Glass), for the README and website.
// Usage: swift Scripts/render-icon.swift <Murmur.app> <output folder>
import AppKit

let app = CommandLine.arguments[1]
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let icon = NSWorkspace.shared.icon(forFile: app)

func save(_ pixels: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

save(1024, "icon-1024.png")
save(256, "icon-256.png")
save(180, "apple-touch-icon.png")
print("Wrote icons to \(out.path)")
