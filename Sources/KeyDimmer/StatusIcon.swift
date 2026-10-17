import AppKit
import KeyDimmerCore

/// Menu bar glyph: a keycap whose glow bar grows with the level, so the current brightness is
/// readable without opening the menu.
enum StatusIcon {
    static func image(for level: Level, in ladder: Ladder) -> NSImage {
        let fill: CGFloat = {
            switch level {
            case .off: return 0
            case let .ember(index, _):
                let embers = ladder.levels.filter(\.isEmber).count
                return 0.08 + 0.32 * CGFloat(index) / CGFloat(max(embers, 1))
            case let .shade(index, _):
                let shades = ladder.levels.filter(\.isShade).count
                return 0.08 + 0.32 * CGFloat(index) / CGFloat(max(shades, 1))
            case let .system(step): return 0.4 + 0.6 * CGFloat(step) / CGFloat(Ladder.systemSteps)
            }
        }()
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let cap = NSRect(x: 1.5, y: 1.5, width: 15, height: 13)
            let outline = NSBezierPath(roundedRect: cap, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1.4
            NSColor.black.setStroke()
            outline.stroke()

            // Inner key top.
            let top = NSBezierPath(roundedRect: cap.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: 1), xRadius: 2, yRadius: 2)
            top.lineWidth = 1
            NSColor.black.withAlphaComponent(0.55).setStroke()
            top.stroke()

            // Glow bar along the bottom edge.
            let track = NSRect(x: 4, y: 3, width: 10, height: 1.6)
            if fill > 0 {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(track.width * fill, 1.6), height: track.height),
                             xRadius: 0.8, yRadius: 0.8).fill()
            } else {
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: track.midX - 0.8, y: track.minY, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "KeyDimmer — \(level.title)"
        return image
    }
}
