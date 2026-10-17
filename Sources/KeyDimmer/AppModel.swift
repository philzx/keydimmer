import AppKit
import CoreGraphics
import KeyDimmerCore
import Observation
import ServiceManagement

/// Adapts SwiftUI, hotkeys and power notifications to the `LightController` (keyboard and built-in
/// display) and renders its state, plus the app-only settings (shortcuts, login item, updates).
/// It holds no light rules.
@MainActor
@Observable
final class AppModel {
    typealias Pause = LightController.Pause

    /// Every light's rules. Nil when this Mac has no light KeyDimmer can drive.
    let controller: LightController?
    /// Why KeyDimmer can't do anything on this Mac: set only when it has no light at all. A Mac
    /// missing just one light simply doesn't show it.
    let unsupportedReason: String?
    let updates = UpdateChecker()
    /// Snapshots only: levels shown without driving the hardware.
    private var previewLevel: Level?
    private var previewDisplayLevel: Level?

    /// Nil when the built-in display can't be driven.
    var displayLadder: Ladder? { controller?.displayLadder }
    var displayLevel: Level? { previewDisplayLevel ?? controller?.displayLevel }
    /// Why shades can't be selected (another gamma app is running), or nil.
    var shadesUnavailableReason: String? { controller?.shadesUnavailableReason }
    var displayLevelIndex: Int { displayLevel.flatMap { displayLadder?.index(of: $0) } ?? 0 }

    var hasKeyboard: Bool { controller?.has(.keyboard) ?? false }
    var hasDisplay: Bool { controller?.has(.display) ?? false }

    var ladder: Ladder { controller?.ladder ?? Ladder(floorPWM: 54) }
    var level: Level { previewLevel ?? controller?.level ?? .off }
    var pause: Pause? { controller?.pause }
    var stats: HoldEngine.Stats { previewLevel == nil ? controller?.stats ?? HoldEngine.Stats() : Self.previewStats }
    var isCalibrating: Bool { controller?.isCalibrating ?? false }
    var floorIsMeasured: Bool { controller?.floorIsMeasured ?? false }
    var calibrationFailed: Bool { controller?.calibrationFailed ?? false }

    var hotkeysEnabled: Bool {
        didSet {
            defaults.set(hotkeysEnabled, forKey: Keys.hotkeys)
            hotKeys.isEnabled = hotkeysEnabled
            unavailableShortcuts = hotKeys.failedLights
        }
    }

    var hotkeyModifiers: HotKeys.Modifiers {
        didSet {
            defaults.set(hotkeyModifiers.rawValue, forKey: Keys.hotkeyModifiers)
            hotKeys.modifiers = hotkeyModifiers
            unavailableShortcuts = hotKeys.failedLights
        }
    }

    /// The lights whose shortcuts are on but macOS wouldn't register (another app has the same keys).
    private(set) var unavailableShortcuts: Set<Light> = []

    var followsInactivity: Bool {
        get { controller?.followsInactivity ?? true }
        set { controller?.followsInactivity = newValue }
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
    private var apps: AppLaunchObserver?

    init() {
        let defaults = UserDefaults.standard
        hotkeysEnabled = defaults.object(forKey: Keys.hotkeys) as? Bool ?? true
        hotkeyModifiers = defaults.string(forKey: Keys.hotkeyModifiers).flatMap(HotKeys.Modifiers.init) ?? .controlOption

        var hardware: BacklightHardware?
        var keyboardReason: String?
        do {
            hardware = try CoreBrightnessBacklight()
        } catch {
            keyboardReason = "\(error)"
        }
        if let found = hardware, found.readPWM() == nil {
            hardware = nil
            keyboardReason = "This Mac has no Apple Silicon keyboard backlight PWM"
        }
        if let keyboardReason { NSLog("KeyDimmer: no keyboard light: \(keyboardReason)") }
        self.hardware = hardware
        var display: DisplayHardware?
        var displayReason: String?
        do {
            display = try BuiltInDisplay()
        } catch {
            NSLog("KeyDimmer: no display light: \(error)")
            displayReason = "\(error)"
        }
        if hardware == nil, display == nil {
            controller = nil
            unsupportedReason = [keyboardReason, displayReason].compactMap { $0 }.joined(separator: ". ")
        } else {
            controller = LightController(
                hardware: hardware, display: display, clock: DispatchClock(), store: defaults,
                secondsSinceLastInput: {
                    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
                }
            )
            unsupportedReason = nil
        }
        if ProcessInfo.processInfo.environment["KEYDIMMER_TRACE"] != nil {
            controller?.onTrace = { message in
                print(message)
                fflush(stdout)
            }
        }
    }

    /// The light the menu bar icon shows: the keyboard if this Mac has one, else the display.
    var iconLevel: Level { hasKeyboard ? level : displayLevel ?? .off }
    var iconLadder: Ladder { hasKeyboard ? ladder : displayLadder ?? ladder }

    var levelIndex: Int { ladder.index(of: level) ?? 0 }

    var dutyDescription: String? {
        guard case let .ember(_, pwm) = level, let controller else { return nil }
        return "\(pwm)/\(controller.totalPeriod)"
    }

    var floorDescription: String? {
        guard let controller, floorIsMeasured else { return nil }
        return "\(ladder.floorPWM)/\(controller.totalPeriod)"
    }

    // MARK: - Lifecycle

    func start() {
        updates.start()
        guard let controller else { return }
        hardware?.observeBrightness { [weak controller] value in
            DispatchQueue.main.async { controller?.brightnessChanged(to: value) }
        }
        // Shortcuts are registered and routed only for the lights this Mac has (`controller.lights`),
        // so an absent light's keys stay free for other apps.
        hotKeys.lights = Set(controller.lights)
        hotKeys.onStep = { [weak controller] light, delta in
            guard let controller, controller.has(light) else { return }
            controller.step(light, by: delta)
        }
        hotKeys.modifiers = hotkeyModifiers
        hotKeys.isEnabled = hotkeysEnabled
        unavailableShortcuts = hotKeys.failedLights
        power = PowerObserver { [weak controller] event in
            switch event {
            case .willSleep: controller?.willSleep()
            case .didWake: controller?.didWake()
            }
        }
        // Before starting, so a saved shade isn't re-applied over another gamma app.
        apps = AppLaunchObserver { [weak controller] event in
            switch event {
            case let .launched(id): controller?.otherGammaAppLaunched(bundleIdentifier: id)
            case let .quit(id): controller?.otherGammaAppQuit(bundleIdentifier: id)
            }
        }
        controller.start()
    }

    func prepareForQuit() { controller?.willQuit() }

    // MARK: - Commands

    func select(index: Int) { controller?.select(index: index) }

    func step(by delta: Int) { controller?.step(by: delta) }

    func selectDisplay(index: Int) { controller?.select(index: index, on: .display) }

    func stepDisplay(by delta: Int) { controller?.step(.display, by: delta) }

    func recalibrate() { controller?.recalibrate() }

    // MARK: - Snapshots

    private static var previewStats: HoldEngine.Stats {
        var stats = HoldEngine.Stats()
        stats.watchdogSamples = 100
        stats.watchdogHits = 100
        return stats
    }

    /// Shows a level without driving the hardware (snapshots only): a keyboard level name, or a
    /// display one prefixed with "display:", e.g. "display:shade:3".
    func preview(levelNamed name: String) {
        if name.hasPrefix("display:") {
            previewDisplayLevel = displayLadder?.level(named: String(name.dropFirst("display:".count)))
        } else {
            previewLevel = controller?.decode(name)
        }
    }
}
