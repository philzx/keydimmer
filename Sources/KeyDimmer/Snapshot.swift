import AppKit
import KeyDimmerCore
import SwiftUI

/// `KeyDimmer --snapshot <out.png> [level]` renders the menu panel to a PNG without touching the
/// backlight — used for the README and for checking layout without screen-recording permission.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else { return }
        let output = URL(fileURLWithPath: arguments[flag + 1])
        let model = AppModel()
        if arguments.count > flag + 2 { model.preview(levelNamed: arguments[flag + 2]) }

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: MenuContent(model: model).background(.regularMaterial))
            host.appearance = NSAppearance(named: appearance)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = appearance == .darkAqua ? "" : "-light"
            let url = output.deletingPathExtension().appendingPathExtension("png")
            let named = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + ".png")
            try? rep.representation(using: .png, properties: [:])?.write(to: named)
        }
        exit(0)
    }
}
