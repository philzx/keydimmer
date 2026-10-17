import Foundation

/// A `kdctl display` command: diagnostics for the built-in display and its shades.
public enum DisplayCommand: Equatable, Sendable {
    /// Print macOS's brightness, the measured nits and the gamma peak.
    case info
    /// Hold a shade of `factor` for `seconds`, reporting any outside changes to the gamma.
    case shade(factor: Float, seconds: TimeInterval)

    public static let usage = "usage: kdctl display [info] | display shade <factor 0<f<=1> [seconds]"
    public static let defaultShadeSeconds: TimeInterval = 10

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses the arguments after `display`.
    public static func parse(_ arguments: [String]) throws -> DisplayCommand {
        switch arguments.first {
        case nil, "info":
            guard arguments.count <= 1 else { throw UsageError(description: usage) }
            return .info
        case "shade":
            guard (2...3).contains(arguments.count) else { throw UsageError(description: usage) }
            // A factor of 0 would black the screen out entirely; NaN fails the range check.
            guard let factor = Float(arguments[1]), factor > 0, factor <= 1 else {
                throw UsageError(description: "kdctl: the shade factor must be above 0 and at most 1")
            }
            var seconds = defaultShadeSeconds
            if arguments.count == 3 {
                guard let parsed = TimeInterval(arguments[2]), parsed > 0, parsed.isFinite else {
                    throw UsageError(description: "kdctl: the seconds must be a positive number")
                }
                seconds = parsed
            }
            return .shade(factor: factor, seconds: seconds)
        default:
            throw UsageError(description: usage)
        }
    }
}

/// A change to the display's gamma table that KeyDimmer didn't make.
public struct GammaChange: Equatable, Sendable {
    public let before: GammaTable
    public let after: GammaTable

    public var peakBefore: Float { before.peak }
    public var peakAfter: Float { after.peak }
}

/// Watches the gamma table during a shade and notices when something else rewrites it.
public struct GammaWatch {
    /// How far an entry may drift before it counts as changed: CoreGraphics reads back the table
    /// it was given with some rounding.
    public static let tolerance: Float = 0.001

    private var expected: GammaTable

    public init(expecting table: GammaTable) {
        expected = table
    }

    /// Compares a fresh read of the table with the last one known; nil while it's unchanged.
    public mutating func observe(_ current: GammaTable) -> GammaChange? {
        guard !Self.matches(current, expected) else { return nil }
        let change = GammaChange(before: expected, after: current)
        expected = current
        return change
    }

    /// Takes `table` as the one in effect, after KeyDimmer has set it itself.
    public mutating func expect(_ table: GammaTable) {
        expected = table
    }

    private static func matches(_ a: GammaTable, _ b: GammaTable) -> Bool {
        func same(_ x: [Float], _ y: [Float]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= tolerance }
        }
        return same(a.red, b.red) && same(a.green, b.green) && same(a.blue, b.blue)
    }
}
