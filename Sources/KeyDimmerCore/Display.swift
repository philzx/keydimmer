import CoreGraphics
import Foundation

/// A display's gamma transfer table: per channel, the output (0...1) for evenly spaced inputs.
public struct GammaTable: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The table every channel scaled by `factor`: how a shade darkens the picture (ADR-0003).
    public func scaled(by factor: Float) -> GammaTable {
        GammaTable(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }

    /// The brightest output of any channel: 1.0 for an unshaded table, the factor for a shaded one.
    public var peak: Float { max(red.last ?? 0, green.last ?? 0, blue.last ?? 0) }
}

/// Everything KeyDimmer needs from a display. The real implementation (`BuiltInDisplay`) talks to
/// DisplayServices, CoreGraphics and IOKit; tests substitute a simulated display.
public protocol DisplayHardware: AnyObject {
    /// macOS's brightness for the display (0...1), as its slider and brightness keys set it.
    func brightness() -> Float
    /// Sets macOS's brightness. Non-zero values below the floor are clamped to it by macOS.
    func setBrightness(_ value: Float)

    /// Darkens the picture by scaling the display's original gamma table by `factor` (0...1).
    /// Successive calls scale the original, not the previous shade.
    func setGamma(factor: Float)
    /// Puts the display's gamma table back to what ColorSync wants.
    func restoreGamma()
    /// The gamma table currently in effect, whoever set it.
    func readGamma() -> GammaTable?

    /// Whether the display can adjust its brightness to the surroundings at all.
    var hasAutoBrightness: Bool { get }
    /// System Settings > Displays > "Automatically adjust brightness".
    var isAutoBrightnessEnabled: Bool { get }
    func setAutoBrightness(_ enabled: Bool)

    /// Calls `handler` (on any queue) whenever macOS reports a new brightness (0...1) for the
    /// display — from the brightness keys, Control Center, another app, or possibly our own sets.
    func observeBrightness(_ handler: @escaping (Float) -> Void)

    /// The backlight's measured luminance in nits, for diagnostics; nil if unavailable.
    func measuredNits() -> Double?
}
