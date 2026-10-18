import Foundation
import Observation

/// Where the controller keeps what must survive a relaunch. `UserDefaults` in the app.
public protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// One of the lights KeyDimmer dims.
public enum Light: Hashable, Sendable, CaseIterable {
    case keyboard
    /// The built-in display.
    case display
}

/// Owns every light this Mac has (the keyboard and the built-in display) and what spans them: the
/// Link, routing commands and events to each light, and the other gamma apps that rule out shades.
/// Each light's own state and rules live in its own type (`KeyboardLight`, `BuiltInDisplayLight`).
/// Each light is independently present: a command or event for a light this Mac doesn't have does
/// nothing.
///
/// It takes commands (select a level, step), receives events (macOS changed the brightness, will
/// sleep, did wake, will quit) and publishes the state the menu renders. It watches the lid and
/// the user's inactivity itself while holding an ember. Everything runs on the clock's queue.
///
/// The keyboard-only members (`ladder`, `level`, `select(_:)`, `step(by:)`, …) predate the display
/// and are shorthands for `.keyboard`. Without a keyboard backlight they keep placeholder values
/// and do nothing; `has(.keyboard)` tells the two apart.
@Observable
public final class LightController {
    public enum Pause: Equatable, Sendable {
        case sleeping
        case lidClosed
        case inactive
    }

    /// The keyboard's ladder.
    public var ladder: Ladder { keyboard?.ladder ?? placeholderLadder }
    /// The keyboard's level.
    public var level: Level { keyboard?.level ?? .off }

    /// The built-in display's ladder: shades, then macOS's steps. Nil without a display to drive.
    public var displayLadder: Ladder? { display?.ladder }
    /// The built-in display's level. Nil without a display to drive.
    public var displayLevel: Level? { display?.level }
    /// Why the display's shades can't be selected right now, as the menu shows it ("Shades are off
    /// while Tint is running"), or nil.
    public private(set) var shadesUnavailableReason: String?
    public var pause: Pause? { keyboard?.pause }
    public var stats: HoldEngine.Stats { keyboard?.stats ?? HoldEngine.Stats() }
    public var isCalibrating: Bool { keyboard?.isCalibrating ?? false }
    /// Whether the ladder comes from a measurement on this Mac and macOS build.
    public var floorIsMeasured: Bool { keyboard?.floorIsMeasured ?? placeholderFloorIsMeasured }
    /// The last recalibration could not measure the floor.
    public var calibrationFailed: Bool { keyboard?.calibrationFailed ?? false }

    /// Whether an ember turns off after macOS's keyboard inactivity timeout, as macOS's own levels do.
    public var followsInactivity: Bool {
        get { keyboard?.followsInactivity ?? KeyboardLight.followsInactivity(in: store) }
        set {
            if let keyboard { keyboard.followsInactivity = newValue } else { store.set(newValue, forKey: KeyboardLight.Keys.followsInactivity) }
        }
    }

    /// The Link: the keyboard follows the built-in display. Turning it on moves the keyboard to the
    /// display's matching level once; adjusting the keyboard by hand afterwards doesn't unlink.
    /// Always off, and can't be turned on, unless this Mac has both lights.
    public var isLinked: Bool {
        get { canLink && linkSetting }
        set {
            guard canLink, newValue != linkSetting else { return }
            linkSetting = newValue
            store.set(newValue, forKey: Keys.isLinked)
            if newValue { followDisplay() }
        }
    }

    private var linkSetting: Bool
    private var canLink: Bool { has(.keyboard) && has(.display) }

    /// Diagnostics trace (KEYDIMMER_TRACE in the app).
    @ObservationIgnored public var onTrace: ((String) -> Void)?

    public var totalPeriod: Int { keyboard?.totalPeriod ?? 0 }

    /// The lights this Mac has, in menu order. Shortcuts and Link should only act on these.
    public var lights: [Light] { Light.allCases.filter(has) }

    public func has(_ light: Light) -> Bool { route(light) != nil }

    public var levelIndex: Int { ladder.index(of: level) ?? 0 }

    private enum Keys {
        static let isLinked = "isLinked"
    }

    /// The keyboard backlight; nil if this Mac has none KeyDimmer can drive.
    @ObservationIgnored private let keyboard: KeyboardLight?
    /// The built-in display; nil if this Mac has none KeyDimmer can drive.
    @ObservationIgnored private let display: BuiltInDisplayLight?
    /// The keyboard's ladder and floor state on a Mac without one, from the floor cache.
    @ObservationIgnored private let placeholderLadder: Ladder
    @ObservationIgnored private let placeholderFloorIsMeasured: Bool
    /// The other gamma apps running, oldest first; one entry per instance.
    @ObservationIgnored private var runningGammaApps: [(bundleIdentifier: String, name: String)] = []
    @ObservationIgnored private let clock: EngineClock
    @ObservationIgnored private let store: SettingsStore

    /// - Parameters:
    ///   - keyboard: the keyboard backlight, or nil if this Mac has none KeyDimmer can drive.
    ///   - display: the built-in display, or nil if this Mac has none KeyDimmer can drive.
    ///   - secondsSinceLastInput: time since the user last touched any input device.
    ///   - hardwareModel, osBuild: identify this Mac and macOS build for the floor cache.
    public init(
        keyboard: BacklightHardware?, display: DisplayHardware? = nil, clock: EngineClock, store: SettingsStore,
        secondsSinceLastInput: @escaping () -> TimeInterval,
        hardwareModel: String = FloorProbe.hardwareModel, osBuild: String = FloorProbe.osBuild
    ) {
        let floorCache = FloorCache(store: store, model: hardwareModel, osBuild: osBuild)
        self.keyboard = keyboard.map {
            KeyboardLight(hardware: $0, clock: clock, store: store, floorCache: floorCache,
                          secondsSinceLastInput: secondsSinceLastInput)
        }
        self.display = display.map { BuiltInDisplayLight(hardware: $0, clock: clock, store: store) }
        let floor = floorCache.floor
        placeholderLadder = Ladder(floorPWM: floor ?? Ladder.assumedFloorPWM)
        placeholderFloorIsMeasured = floor != nil
        self.clock = clock
        self.store = store
        linkSetting = store.object(forKey: Keys.isLinked) as? Bool ?? false
        self.keyboard?.onTrace = { [weak self] in self?.trace($0) }
        self.display?.onTrace = { [weak self] in self?.trace($0) }
        // Every change of the display's level, whoever causes it, is where the Link makes the keyboard follow.
        self.display?.onLevelChange = { [weak self] in self?.followDisplay() }
    }

    /// The light this Mac has for `light`, or nil: the one place commands pick a light.
    private func route(_ light: Light) -> (any LightRules)? {
        switch light {
        case .keyboard: return keyboard
        case .display: return display
        }
    }

    // MARK: - Lifecycle

    /// Puts right what a crash may have left behind, then returns to the saved ember or shade, or
    /// shows whatever macOS is at.
    public func start() {
        keyboard?.start()
        display?.start()
    }

    /// Leaves each light as dim as macOS can keep it without us, and hands features back.
    public func willQuit() {
        keyboard?.willQuit()
        display?.willQuit()
    }

    /// How long after waking the lights wait before returning to their levels, giving
    /// CoreBrightness (and the display's own restore) a moment to settle first.
    static let wakeGrace: TimeInterval = 1

    /// The Mac or its displays are going to sleep. Locking the screen is not sleep: a shade stays.
    public func willSleep() {
        display?.willSleep()
        keyboard?.willSleep()
    }

    /// The Mac or its displays woke up.
    public func didWake() {
        display?.didWake()
        keyboard?.didWake()
    }

    // MARK: - Selection

    /// The light's ladder; nil if this Mac doesn't have the light.
    public func ladder(of light: Light) -> Ladder? { route(light)?.ladder }

    /// The light's current level; nil if this Mac doesn't have the light.
    public func level(of light: Light) -> Level? { route(light)?.currentLevel }

    public func select(_ level: Level, on light: Light) { route(light)?.select(level) }

    public func select(index: Int, on light: Light) {
        guard let ladder = ladder(of: light) else { return }
        select(ladder.level(at: index), on: light)
    }

    /// Does nothing at either end, where a held shortcut keeps repeating.
    public func step(_ light: Light, by delta: Int) {
        guard let ladder = ladder(of: light), let current = level(of: light).flatMap(ladder.index(of:)) else { return }
        let index = min(max(current + delta, 0), ladder.count - 1)
        if index != current { select(index: index, on: light) }
    }

    public func select(index: Int) { select(index: index, on: .keyboard) }

    public func step(by delta: Int) { step(.keyboard, by: delta) }

    public func select(_ newLevel: Level) { keyboard?.select(newLevel) }

    /// Measures the keyboard's floor again, then returns to the current level on the (possibly
    /// rebuilt) ladder.
    public func recalibrate() { keyboard?.recalibrate() }

    /// macOS reported a new keyboard brightness target; see `KeyboardLight.brightnessChanged()`.
    public func brightnessChanged(to value: Float) {
        trace("brightness notification \(value)")
        keyboard?.brightnessChanged()
    }

    // MARK: - Automatic brightness

    /// The built-in display came online while running without it (the lid opened in clamshell
    /// mode). This run doesn't drive it, but automatic brightness that a crash on a shade left
    /// paused is handed back now rather than at the next launch.
    public func builtInDisplayAppeared(_ builtIn: DisplayHardware) {
        guard display == nil else { return }
        trace("built-in display appeared")
        BuiltInDisplayLight.autoBrightnessRecord(in: store).handBack(set: builtIn.setAutoBrightness)
    }

    // MARK: - Conflicting gamma apps

    /// Another gamma app (the app layer matches `GammaApps`) was launched, or was running when
    /// KeyDimmer started. Any shade is removed, leaving the display at its floor, and shades stay
    /// unavailable until it quits.
    public func otherGammaAppLaunched(bundleIdentifier: String, name: String) {
        trace("gamma app launched \(bundleIdentifier)")
        runningGammaApps.append((bundleIdentifier, name))
        updateShadesUnavailableReason()
    }

    /// A gamma app quit. Once none is left, shades can be selected again; the display stays where it is.
    public func otherGammaAppQuit(bundleIdentifier: String) {
        guard let index = runningGammaApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        trace("gamma app quit \(bundleIdentifier)")
        runningGammaApps.remove(at: index)
        updateShadesUnavailableReason()
    }

    private func updateShadesUnavailableReason() {
        shadesUnavailableReason = runningGammaApps.first.map { "Shades are off while \($0.name) is running" }
        display?.shadesAreAvailable = shadesUnavailableReason == nil
    }

    // MARK: - Link

    /// Under the Link, puts the keyboard on the level matching the display's.
    private func followDisplay() {
        guard isLinked, let displayLevel, let target = linkedKeyboardLevel(for: displayLevel) else { return }
        if target != level { select(target) }
    }

    /// The keyboard level the Link pairs with a display level. Shades map onto embers and system
    /// steps onto the same system step; within each zone the position is proportional, so the
    /// dimmest and brightest shades land on the dimmest and brightest embers.
    private func linkedKeyboardLevel(for displayLevel: Level) -> Level? {
        switch displayLevel {
        case let .shade(index, _):
            let shadeCount = displayLadder?.shadeCount ?? 0
            let emberCount = ladder.emberCount
            guard shadeCount > 0, emberCount > 0 else { return nil }
            let fraction = shadeCount > 1 ? Double(index - 1) / Double(shadeCount - 1) : 1
            return ladder.ember(1 + Int((fraction * Double(emberCount - 1)).rounded()))
        case let .system(step):
            return .system(step: step)
        case .off, .ember:
            return nil
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard let onTrace else { return }
        onTrace(String(format: "%.3f ", clock.now) + message())
    }

    // MARK: - Persistence

    /// Reads a keyboard level name ("off", "ember:3", "system:8") on this controller's ladder.
    public func decode(_ string: String) -> Level? { ladder.level(named: string) }
}

/// What the controller needs from every light to route commands to it.
protocol LightRules: AnyObject {
    var ladder: Ladder { get }
    /// Nil until the light has read its level.
    var currentLevel: Level? { get }
    func select(_ level: Level)
}

extension KeyboardLight: LightRules {
    var currentLevel: Level? { level }
}

extension BuiltInDisplayLight: LightRules {
    var currentLevel: Level? { level }
}

/// A light's automatic brightness, turned off while KeyDimmer holds it below the floor. How it was
/// first found is persisted under `key`, so a crash leaves it for the next launch to hand back.
struct AutoBrightnessRecord {
    let store: SettingsStore
    let key: String

    /// Turns automatic brightness off, recording how it was first found, so moving between embers
    /// or shades keeps the original.
    func takeOver(isEnabled: Bool, set: (Bool) -> Void) {
        if store.object(forKey: key) == nil { store.set(isEnabled, forKey: key) }
        set(false)
    }

    /// Puts automatic brightness back as recorded and clears the record; does nothing without one.
    func handBack(set: (Bool) -> Void) {
        guard let auto = store.object(forKey: key) as? Bool else { return }
        set(auto)
        store.removeObject(forKey: key)
    }
}

/// The keyboard floor measured on this Mac, kept with the macOS build it was measured on.
struct FloorCache {
    let store: SettingsStore
    let key: String
    let buildKey: String
    let osBuild: String

    init(store: SettingsStore, model: String, osBuild: String) {
        self.store = store
        key = FloorProbe.cacheKey(model: model)
        buildKey = key + ".osBuild"
        self.osBuild = osBuild
    }

    /// The measured floor, unless it was taken on another macOS build.
    var floor: Int? {
        guard store.object(forKey: buildKey) as? String == osBuild,
              let floor = store.object(forKey: key) as? Int, floor >= FloorProbe.minimumPlausibleFloor
        else { return nil }
        return floor
    }

    func save(_ floor: Int) {
        store.set(floor, forKey: key)
        store.set(osBuild, forKey: buildKey)
    }
}
