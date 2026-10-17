// Renders Resources/AppIcon.icns: a charcoal tile with a single keycap lit by a low ember glow.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KeyDimmer.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024

    // Tile.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.14, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)])!
        .draw(in: tilePath, angle: -90)

    // Ember glow spilling from under the key.
    let glowCenter = NSPoint(x: 512 * s, y: 330 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.55, blue: 0.2, alpha: 0.75),
                        NSColor(calibratedRed: 1, green: 0.35, blue: 0.1, alpha: 0.18),
                        NSColor(calibratedRed: 1, green: 0.3, blue: 0.1, alpha: 0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 360 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // Keycap body and top.
    let cap = NSRect(x: 292 * s, y: 330 * s, width: 440 * s, height: 400 * s)
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: cap, xRadius: 70 * s, yRadius: 70 * s).fill()
    let top = cap.insetBy(dx: 52 * s, dy: 52 * s).offsetBy(dx: 0, dy: 26 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.2, green: 0.19, blue: 0.21, alpha: 1),
                        NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.15, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: top, xRadius: 46 * s, yRadius: 46 * s), angle: -90)

    // Lit edge along the bottom of the key.
    let edge = NSBezierPath(roundedRect: NSRect(x: 340 * s, y: 338 * s, width: 344 * s, height: 22 * s), xRadius: 11 * s, yRadius: 11 * s)
    NSColor(calibratedRed: 1, green: 0.62, blue: 0.3, alpha: 1).setFill()
    edge.fill()

    // A dim glyph: a crescent-less "low" mark — three dots fading out.
    for (i, alpha) in [0.95, 0.5, 0.2].enumerated() {
        NSColor(calibratedRed: 1, green: 0.6, blue: 0.28, alpha: alpha).setFill()
        let d = 34 * s
        NSBezierPath(ovalIn: NSRect(x: (440 + CGFloat(i) * 56) * s - d / 2 + 16 * s, y: 548 * s, width: d, height: d)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try! process.run()
process.waitUntilExit()
exit(process.terminationStatus)
