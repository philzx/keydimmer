import AppKit
import CoreGraphics
import KeyDimmerCore
import Observation
import ServiceManagement

/// Adapts SwiftUI, hotkeys and power notifications to the keyboard's `LightController` and renders
/// its state, plus the app-only settings (shortcuts, login item, updates). It holds no light rules.
@MainActor
@Observable
final class AppModel {
    typealias Pause = LightController.Pause

    /// Nil when this Mac has no keyboard backlight KeyDimmer can drive.
    let keyboard: LightController?
    let unsupportedReason: String?
    let updates = UpdateChecker()
    /// Snapshots only: a level shown without driving the hardware.
    private var previewLevel: Level?

    var ladder: Ladder { keyboard?.ladder ?? Ladder(floorPWM: 54) }
    var level: Level { previewLevel ?? keyboard?.level ?? .off }
    var pause: Pause? { keyboard?.pause }
    var stats: HoldEngine.Stats { previewLevel == nil ? keyboard?.stats ?? HoldEngine.Stats() : Self.previewStats }
    var isCalibrating: Bool { keyboard?.isCalibrating ?? false }
    var floorIsMeasured: Bool { keyboard?.floorIsMeasured ?? false }
    var calibrationFailed: Bool { keyboard?.calibrationFailed ?? false }

    var hotkeysEnabled: Bool {
        didSet {
            defaults.set(hotkeysEnabled, forKey: Keys.hotkeys)
            hotKeys.isEnabled = hotkeysEnabled
            hotkeysUnavailable = hotKeys.registrationFailed
        }
    }

    var hotkeyModifiers: HotKeys.Modifiers {
        didSet {
            defaults.set(hotkeyModifiers.rawValue, forKey: Keys.hotkeyModifiers)
            hotKeys.modifiers = hotkeyModifiers
            hotkeysUnavailable = hotKeys.registrationFailed
        }
    }

    /// The shortcuts are on but macOS wouldn't register them (another app has the same keys).
    private(set) var hotkeysUnavailable = false

    var followsInactivity: Bool {
        get { keyboard?.followsInactivity ?? true }
        set { keyboard?.followsInactivity = newValue }
    }

    /// On once registered, including while macOS waits for the user to approve it.
    var launchAtLogin: Bool {
        get { _ = launchAtLoginRevision; return [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                NSLog("KeyDimmer: launch at login change failed: \(error)")
                launchAtLoginError = error.localizedDescription
            }
            launchAtLoginRevision += 1
        }
    }

    var launchAtLoginNeedsApproval: Bool {
        _ = launchAtLoginRevision
        return SMAppService.mainApp.status == .requiresApproval
    }

    private(set) var launchAtLoginError: String?
    /// Bumped so SwiftUI re-reads the login item status, which lives outside this object.
    private var launchAtLoginRevision = 0

    /// The user may have approved or removed the login item in System Settings since we last looked.
    func refreshLaunchAtLogin() { launchAtLoginRevision += 1 }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    private enum Keys {
        static let hotkeys = "hotkeysEnabled"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    private let defaults = UserDefaults.standard
    private let hardware: BacklightHardware?
    private let hotKeys = HotKeys()
    private var power: PowerObserver?

    init() {
        let defaults = UserDefaults.standard
        hotkeysEnabled = defaults.object(forKey: Keys.hotkeys) as? Bool ?? true
        hotkeyModifiers = defaults.string(forKey: Keys.hotkeyModifiers).flatMap(HotKeys.Modifiers.init) ?? .controlOption

        var hardware: BacklightHardware?
        var reason: String?
        do {
            hardware = try CoreBrightnessBacklight()
        } catch {
            reason = "\(error)"
        }
        if let found = hardware, found.readPWM() == nil {
            hardware = nil
            reason = "This Mac has no Apple Silicon keyboard backlight PWM"
        }
        self.hardware = hardware
        unsupportedReason = reason
        keyboard = hardware.map { hardware in
            LightController(
                hardware: hardware, clock: DispatchClock(), store: defaults,
                secondsSinceLastInput: {
                    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
                }
            )
        }
        if ProcessInfo.processInfo.environment["KEYDIMMER_TRACE"] != nil {
            keyboard?.onTrace = { message in
                print(message)
                fflush(stdout)
            }
        }
    }

    var isSupported: Bool { unsupportedReason == nil }

    var levelIndex: Int { ladder.index(of: level) ?? 0 }

    var dutyDescription: String? {
        guard case let .ember(_, pwm) = level, let keyboard else { return nil }
        return "\(pwm)/\(keyboard.totalPeriod)"
    }

    var floorDescription: String? {
        guard let keyboard, floorIsMeasured else { return nil }
        return "\(ladder.floorPWM)/\(keyboard.totalPeriod)"
    }

    // MARK: - Lifecycle

    func start() {
        updates.start()
        guard let hardware, let keyboard else { return }
        hardware.observeBrightness { [weak keyboard] value in
            DispatchQueue.main.async { keyboard?.brightnessChanged(to: value) }
        }
        hotKeys.onStep = { [weak self] delta in self?.step(by: delta) }
        hotKeys.modifiers = hotkeyModifiers
        hotKeys.isEnabled = hotkeysEnabled
        hotkeysUnavailable = hotKeys.registrationFailed
        power = PowerObserver { [weak keyboard] event in
            switch event {
            case .willSleep: keyboard?.willSleep()
            case .didWake: keyboard?.didWake()
            }
        }
        keyboard.start()
    }

    func prepareForQuit() { keyboard?.willQuit() }

    // MARK: - Commands

    func select(index: Int) { keyboard?.select(index: index) }

    func step(by delta: Int) { keyboard?.step(by: delta) }

    func recalibrate() { keyboard?.recalibrate() }

    // MARK: - Snapshots

    private static var previewStats: HoldEngine.Stats {
        var stats = HoldEngine.Stats()
        stats.watchdogSamples = 100
        stats.watchdogHits = 100
        return stats
    }

    /// Shows a level without driving the hardware (snapshots only).
    func preview(levelNamed name: String) {
        previewLevel = keyboard?.decode(name)
    }
}
