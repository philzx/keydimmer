import Foundation

/// One position on KeyDimmer's single slider.
public enum Level: Equatable, Hashable, Sendable {
    case off
    /// A sub-minimum level, held by KeyDimmer at `pwm` / totalPeriod duty. `index` starts at 1 (dimmest).
    case ember(index: Int, pwm: Int)
    /// One of macOS's own 16 keyboard brightness steps (1...16).
    case system(step: Int)

    public var isEmber: Bool {
        if case .ember = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case let .ember(index, _): return "Ember \(index)"
        case let .system(step): return "macOS \(step)"
        }
    }

    /// Brightness value handed to CoreBrightness for a system step.
    public static func systemBrightness(step: Int) -> Float { Float(step) / 16 }
}

/// The ordered list of slider positions: Off, the sub-minimum embers, then the 16 macOS steps.
///
/// Unlike fixed PWM targets, the embers are spread geometrically between a duty of 1 count and
/// most of the way to this Mac's own floor, so there is no visual gap between the brightest
/// ember and the dimmest macOS step regardless of the panel's floor.
public struct Ladder: Equatable, Sendable {
    public static let emberCount = 12
    public static let systemSteps = 16

    public let floorPWM: Int
    public let levels: [Level]

    public init(floorPWM: Int, emberCount: Int = Ladder.emberCount) {
        self.floorPWM = floorPWM
        let embers = Self.emberTargets(floorPWM: floorPWM, count: emberCount)
        levels = [.off]
            + embers.enumerated().map { Level.ember(index: $0.offset + 1, pwm: $0.element) }
            + (1...Self.systemSteps).map { Level.system(step: $0) }
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

    /// The macOS step closest to an arbitrary CoreBrightness value (used when someone else changes it).
    public func nearestLevel(forBrightness value: Float) -> Level {
        if value <= 0 { return .off }
        let step = Int((value * 16).rounded())
        return .system(step: min(max(step, 1), Self.systemSteps))
    }
}
