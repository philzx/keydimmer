import Foundation
import IOKit

/// Everything KeyDimmer needs from the keyboard backlight. The real implementation talks to
/// CoreBrightness and IOKit; tests substitute a simulated panel.
public protocol BacklightHardware: AnyObject {
    /// Current PWM high period (duty numerator), or nil if the IOKit service is unavailable.
    func readPWM() -> Int?
    /// PWM period (duty denominator). 960 on every Apple Silicon MacBook observed so far.
    var totalPeriod: Int { get }
    /// Last brightness target CoreBrightness accepted (0...1).
    func brightness() -> Float
    /// Starts a linear fade from the current output to `value` over a duration selected by `fadeSpeed`.
    /// Any non-zero value is clamped by macOS to its hardware floor; only 0 fades below it.
    func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool)
    var isAutoBrightnessEnabled: Bool { get }
    func setAutoBrightness(_ enabled: Bool)
    func setIdleDimmingSuspended(_ suspended: Bool)
    /// The user's "turn keyboard backlight off after inactivity" setting in seconds; 0 means never.
    /// Querying it makes CoreBrightness re-evaluate the backlight and disturbs a fade in flight, so
    /// read it before holding, never during.
    func idleDimTime() -> TimeInterval
    /// True while the lid is closed (e.g. clamshell mode with an external display).
    func isLidClosed() -> Bool
    /// Calls `handler` (on any queue) whenever CoreBrightness reports a new brightness target.
    func observeBrightness(_ handler: @escaping (Float) -> Void)
}

public enum BacklightError: Error, CustomStringConvertible {
    case frameworkNotFound
    case clientUnavailable
    case noKeyboard

    public var description: String {
        switch self {
        case .frameworkNotFound: return "CoreBrightness.framework could not be loaded"
        case .clientUnavailable: return "KeyboardBrightnessClient is not available on this macOS version"
        case .noKeyboard: return "No built-in keyboard backlight was found"
        }
    }
}

/// Method shapes of the private `KeyboardBrightnessClient` class (CoreBrightness.framework).
/// Type encodings were verified at runtime with `class_copyMethodList`.
@objc private protocol KeyboardBrightnessClientAPI {
    func copyKeyboardBacklightIDs() -> NSArray?
    func brightnessForKeyboard(_ keyboardID: UInt64) -> Float
    func setBrightness(_ brightness: Float, fadeSpeed: Int32, commit: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func isAutoBrightnessEnabledForKeyboard(_ keyboardID: UInt64) -> Bool
    func enableAutoBrightness(_ enabled: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func suspendIdleDimming(_ suspend: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func idleDimTimeForKeyboard(_ keyboardID: UInt64) -> Double
    func isKeyboardBuiltIn(_ keyboardID: UInt64) -> Bool
    func registerNotificationForKeys(_ keys: NSArray, keyboardID: UInt64, block: @escaping (AnyObject?, AnyObject?) -> Void)
}

public final class CoreBrightnessBacklight: BacklightHardware {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    private let clientObject: NSObject
    private let client: KeyboardBrightnessClientAPI
    public let keyboardID: UInt64
    private let pwmService: io_service_t
    public let totalPeriod: Int

    public init() throws {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil else { throw BacklightError.frameworkNotFound }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            throw BacklightError.clientUnavailable
        }
        let object = cls.init()
        let api = unsafeBitCast(object, to: KeyboardBrightnessClientAPI.self)
        let ids = (api.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        let builtIn = ids.first { id in
            !object.responds(to: NSSelectorFromString("isKeyboardBuiltIn:")) || api.isKeyboardBuiltIn(id)
        }
        guard let keyboardID = builtIn ?? ids.first else { throw BacklightError.noKeyboard }

        clientObject = object
        client = api
        self.keyboardID = keyboardID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("kbd-backlight"))
        pwmService = service
        totalPeriod = Self.readInt(service, "high-period").flatMap { high in
            Self.readInt(service, "low-period").map { high + $0 }
        } ?? 960
    }

    deinit {
        if pwmService != 0 { IOObjectRelease(pwmService) }
    }

    private static func readInt(_ service: io_service_t, _ key: String) -> Int? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return (value.takeRetainedValue() as? NSNumber)?.intValue
    }

    public func readPWM() -> Int? { Self.readInt(pwmService, "high-period") }

    public func brightness() -> Float { client.brightnessForKeyboard(keyboardID) }

    public func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool) {
        _ = client.setBrightness(value, fadeSpeed: fadeSpeed, commit: commit, forKeyboard: keyboardID)
    }

    public var isAutoBrightnessEnabled: Bool { client.isAutoBrightnessEnabledForKeyboard(keyboardID) }

    public func setAutoBrightness(_ enabled: Bool) {
        _ = client.enableAutoBrightness(enabled, forKeyboard: keyboardID)
    }

    public func setIdleDimmingSuspended(_ suspended: Bool) {
        _ = client.suspendIdleDimming(suspended, forKeyboard: keyboardID)
    }

    public func idleDimTime() -> TimeInterval { client.idleDimTimeForKeyboard(keyboardID) }

    // `isBacklightSuppressedOnKeyboard:` is no use here: it reports true whenever the fade goal is 0,
    // which is half of every hold cycle.
    public func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    public func observeBrightness(_ handler: @escaping (Float) -> Void) {
        client.registerNotificationForKeys(["KeyboardBacklightBrightness"] as NSArray, keyboardID: keyboardID) { key, value in
            guard (key as? String) == "KeyboardBacklightBrightness", let number = value as? NSNumber else { return }
            handler(number.floatValue)
        }
    }
}
