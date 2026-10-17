import Foundation

/// One position on KeyDimmer's single slider.
public enum Level: Equatable, Hashable, Sendable {
    case off
    /// A sub-minimum level, held by KeyDimmer at `pwm` / totalPeriod duty. `index` starts at 1 (dimmest).
    case ember(index: Int, pwm: Int)
    /// A sub-floor level made by scaling the picture's gamma by `factor` (0...1) while the display
    /// sits at its floor. `index` starts at 1 (darkest).
    case shade(index: Int, factor: Float)
    /// One of macOS's own 16 brightness steps (1...16).
    case system(step: Int)

    public var isEmber: Bool {
        if case .ember = self { return true }
        return false
    }

    public var isShade: Bool {
        if case .shade = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case let .ember(index, _): return "Ember \(index)"
        case let .shade(index, _): return "Shade \(index)"
        case let .system(step): return "macOS \(step)"
        }
    }

    /// How the level is saved across launches: "off", "ember:3", "shade:2" or "system:8".
    /// Embers and shades are saved by index, so they land on the same position of a rebuilt ladder.
    public var storageName: String {
        switch self {
        case .off: return "off"
        case let .ember(index, _): return "ember:\(index)"
        case let .shade(index, _): return "shade:\(index)"
        case let .system(step): return "system:\(step)"
        }
    }

    /// Brightness value handed to macOS for a system step.
    public static func systemBrightness(step: Int) -> Float { Float(step) / 16 }
}

/// The ordered list of slider positions for one light.
///
/// The keyboard's ladder is Off, the sub-minimum embers, then the 16 macOS steps. Unlike fixed PWM
/// targets, the embers are spread geometrically between a duty of 1 count and most of the way to
/// this Mac's own floor, so there is no visual gap between the brightest ember and the dimmest
/// macOS step regardless of the panel's floor.
///
/// The built-in display's ladder (`Ladder.display()`) is the shades, then the 16 macOS steps. It
/// has no Off, so the screen can't be blanked from the slider, and no embers (ADR-0003).
public struct Ladder: Equatable, Sendable {
    public static let emberCount = 12
    public static let systemSteps = 16
    public static let shadeCount = 8
    /// How much of the picture the darkest shade keeps. Tuned by eye on hardware: dark enough to
    /// matter in a dark room, light enough to stay readable.
    public static let darkestShade: Float = 0.12

    /// The keyboard's measured floor; 0 on a ladder without embers.
    public let floorPWM: Int
    public let levels: [Level]

    public init(floorPWM: Int, emberCount: Int = Ladder.emberCount) {
        self.floorPWM = floorPWM
        let embers = Self.emberTargets(floorPWM: floorPWM, count: emberCount)
        levels = [.off]
            + embers.enumerated().map { Level.ember(index: $0.offset + 1, pwm: $0.element) }
            + Self.systemLevels
    }

    private init(levels: [Level]) {
        floorPWM = 0
        self.levels = levels
    }

    private static var systemLevels: [Level] { (1...systemSteps).map { Level.system(step: $0) } }

    /// The built-in display's ladder: the shades, then the macOS steps, with the floor (the dimmest
    /// step) in between.
    public static func display(shadeCount: Int = Ladder.shadeCount, darkestShade: Float = Ladder.darkestShade) -> Ladder {
        let shades = shadeFactors(count: shadeCount, darkest: darkestShade)
        return Ladder(levels: shades.enumerated().map { Level.shade(index: $0.offset + 1, factor: $0.element) } + systemLevels)
    }

    /// Gamma factors from `darkest` up to just under 1, spaced geometrically so that each shade
    /// looks like the same change in darkness. The unshaded floor (1.0) is the next term of the
    /// series, so the step from the brightest shade to the dimmest macOS step is the same size too.
    public static func shadeFactors(count: Int, darkest: Float) -> [Float] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in pow(darkest, Float(count - i) / Float(count)) }
    }

    /// Strictly increasing integer PWM targets from 1 up to ~80% of `floorPWM`, geometrically spaced
    /// (perceived brightness is roughly logarithmic in duty).
    public static func emberTargets(floorPWM: Int, count: Int) -> [Int] {
        let top = max(Int((Double(floorPWM) * 0.8).rounded()), 1)
        let usable = min(count, top)
        guard usable > 1 else { return [1] }
        let ratio = pow(Double(top), 1 / Double(usable - 1))
        var targets: [Int] = []
        for i in 0..<usable {
            let ideal = Int(pow(ratio, Double(i)).rounded())
            let floorForStep = (targets.last ?? 0) + 1
            // Leave room for the remaining steps below `top`.
            let ceilingForStep = top - (usable - 1 - i)
            targets.append(min(max(ideal, floorForStep), ceilingForStep))
        }
        return targets
    }

    public var count: Int { levels.count }

    public func index(of level: Level) -> Int? { levels.firstIndex(of: level) }

    public func level(at index: Int) -> Level { levels[min(max(index, 0), levels.count - 1)] }

    /// The ember with this 1-based index, clamped to the embers this floor allows.
    public func ember(_ index: Int) -> Level? {
        let embers = levels.filter(\.isEmber)
        guard !embers.isEmpty else { return nil }
        return embers[min(max(index, 1), embers.count) - 1]
    }

    /// The shade with this 1-based index, clamped to the shades on this ladder.
    public func shade(_ index: Int) -> Level? {
        let shades = levels.filter(\.isShade)
        guard !shades.isEmpty else { return nil }
        return shades[min(max(index, 1), shades.count) - 1]
    }

    /// Reads a `Level.storageName` back on this ladder; nil if this ladder has no such kind of level.
    public func level(named name: String) -> Level? {
        let parts = name.split(separator: ":")
        switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
        case ("off", _): return levels.first == .off ? .off : nil
        case let ("ember", index?): return ember(index)
        case let ("shade", index?): return shade(index)
        case let ("system", step?): return .system(step: min(max(step, 1), Self.systemSteps))
        default: return nil
        }
    }

    /// The level macOS is at for an arbitrary brightness value (used when someone else changes it):
    /// Off for 0 if this ladder has Off, otherwise the closest macOS step.
    public func nearestLevel(forBrightness value: Float) -> Level {
        if value <= 0, levels.first == .off { return .off }
        let step = Int((value * 16).rounded())
        return .system(step: min(max(step, 1), Self.systemSteps))
    }
}
