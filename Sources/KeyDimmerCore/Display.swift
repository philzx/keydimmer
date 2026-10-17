import CoreGraphics
import Foundation
import IOKit

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

public enum DisplayError: Error, CustomStringConvertible {
    case noBuiltInDisplay
    case frameworkNotFound
    case symbolMissing(String)
    case brightnessNotAdjustable

    public var description: String {
        switch self {
        case .noBuiltInDisplay: return "No built-in display was found"
        case .frameworkNotFound: return "DisplayServices.framework could not be loaded"
        case let .symbolMissing(name): return "\(name) is not available on this macOS version"
        case .brightnessNotAdjustable: return "The built-in display's brightness can't be changed"
        }
    }
}

/// The Mac's built-in display: brightness through the private DisplayServices framework, shades
/// through CoreGraphics gamma tables, measured nits from the built-in framebuffer in the IORegistry.
public final class BuiltInDisplay: DisplayHardware {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetFloat = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFloat = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias DisplayPredicate = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBool = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SetBool = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    private typealias Register = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback) -> Int32

    public let displayID: CGDirectDisplayID
    private let getBrightness: GetFloat
    private let setBrightnessFunction: SetFloat
    private let hasALC: DisplayPredicate?
    private let alcEnabled: GetBool?
    private let enableALC: SetBool?
    private let registerForBrightness: Register?
    /// The table ColorSync had in effect before our first shade; shades scale this, never a shade.
    private var original: GammaTable?
    private var isShaded = false

    public init() throws {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw DisplayError.noBuiltInDisplay
        }
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { throw DisplayError.frameworkNotFound }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        func required<T>(_ name: String, as type: T.Type) throws -> T {
            guard let found = symbol(name, as: type) else { throw DisplayError.symbolMissing(name) }
            return found
        }
        displayID = builtIn
        getBrightness = try required("DisplayServicesGetBrightness", as: GetFloat.self)
        setBrightnessFunction = try required("DisplayServicesSetBrightness", as: SetFloat.self)
        if let canChange = symbol("DisplayServicesCanChangeBrightness", as: DisplayPredicate.self), !canChange(builtIn) {
            throw DisplayError.brightnessNotAdjustable
        }
        hasALC = symbol("DisplayServicesHasAmbientLightCompensation", as: DisplayPredicate.self)
        alcEnabled = symbol("DisplayServicesAmbientLightCompensationEnabled", as: GetBool.self)
        enableALC = symbol("DisplayServicesEnableAmbientLightCompensation", as: SetBool.self)
        registerForBrightness = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", as: Register.self)
    }

    // MARK: Brightness

    public func brightness() -> Float {
        var value: Float = 0
        _ = getBrightness(displayID, &value)
        return value
    }

    public func setBrightness(_ value: Float) {
        _ = setBrightnessFunction(displayID, value)
    }

    // MARK: Gamma

    public func setGamma(factor: Float) {
        if !isShaded { original = readGamma() }
        guard let original, !original.green.isEmpty else { return }
        let table = original.scaled(by: factor)
        CGSetDisplayTransferByTable(displayID, UInt32(table.green.count), table.red, table.green, table.blue)
        isShaded = true
    }

    /// Resets every display's gamma to ColorSync's; fine while the built-in display is the only
    /// light with shades.
    public func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
        isShaded = false
    }

    public func readGamma() -> GammaTable? {
        let capacity = Int(CGDisplayGammaTableCapacity(displayID))
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: capacity), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, UInt32(capacity), &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return GammaTable(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    // MARK: Automatic brightness (DisplayServices' ambient light compensation)

    public var hasAutoBrightness: Bool {
        guard let hasALC, alcEnabled != nil, enableALC != nil else { return false }
        return hasALC(displayID)
    }

    public var isAutoBrightnessEnabled: Bool {
        guard hasAutoBrightness, let alcEnabled else { return false }
        var enabled = false
        return alcEnabled(displayID, &enabled) == 0 && enabled
    }

    public func setAutoBrightness(_ enabled: Bool) {
        guard hasAutoBrightness, let enableALC else { return }
        _ = enableALC(displayID, enabled)
    }

    // MARK: Brightness notifications

    /// DisplayServices calls back through a C function that can't capture context, so handlers are
    /// kept here by display; the callback's observer argument echoes the display ID we registered.
    private static let handlersLock = NSLock()
    private static var handlers: [CGDirectDisplayID: [(Float) -> Void]] = [:]

    private static let brightnessCallback: CFNotificationCallback = { _, observer, _, _, userInfo in
        let display = CGDirectDisplayID(truncatingIfNeeded: UInt(bitPattern: observer))
        guard let value = (userInfo as NSDictionary?)?["value"] as? NSNumber else { return }
        handlersLock.lock()
        let registered = handlers[display] ?? []
        handlersLock.unlock()
        registered.forEach { $0(value.floatValue) }
    }

    public func observeBrightness(_ handler: @escaping (Float) -> Void) {
        guard let registerForBrightness else { return }
        Self.handlersLock.lock()
        let first = Self.handlers[displayID] == nil
        Self.handlers[displayID, default: []].append(handler)
        Self.handlersLock.unlock()
        if first { _ = registerForBrightness(displayID, displayID, Self.brightnessCallback) }
    }

    // MARK: Measured luminance

    /// `IOMFBBrightnessLevel` on the built-in framebuffer shim (under `disp0`), in nits as 16.16
    /// fixed point. It tracks the panel live, unlike the backlight's static display parameters.
    public func measuredNits() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var path = [CChar](repeating: 0, count: 1024)
            guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS,
                  String(cString: path).contains("/disp0@") else { continue }
            let value = IORegistryEntryCreateCFProperty(service, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)
            guard let level = (value?.takeRetainedValue() as? NSNumber)?.doubleValue else { return nil }
            return level / 65536
        }
        return nil
    }
}
