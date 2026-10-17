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

/// Owns every light this Mac has (the keyboard and the built-in display), their ladders and every
/// rule about them. Each light is independently present: a command or event for a light this Mac
/// doesn't have does nothing.
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
    public private(set) var ladder: Ladder
    /// The keyboard's level.
    public private(set) var level: Level = .off

    /// The built-in display's ladder: shades, then macOS's steps. Nil without a display to drive.
    public let displayLadder: Ladder?
    /// The built-in display's level. Nil without a display to drive.
    public private(set) var displayLevel: Level?
    /// Why the display's shades can't be selected right now (another gamma app is running), or nil.
    public private(set) var shadesUnavailableReason: String?
    public private(set) var pause: Pause?
    public private(set) var stats = HoldEngine.Stats()
    public private(set) var isCalibrating = false
    /// Whether the ladder comes from a measurement on this Mac and macOS build.
    public private(set) var floorIsMeasured = false
    /// The last recalibration could not measure the floor.
    public private(set) var calibrationFailed = false

    /// Whether an ember turns off after macOS's keyboard inactivity timeout, as macOS's own levels do.
    public var followsInactivity: Bool {
        didSet { store.set(followsInactivity, forKey: Keys.followsInactivity) }
    }

    /// Diagnostics trace (KEYDIMMER_TRACE in the app).
    @ObservationIgnored public var onTrace: ((String) -> Void)?

    public var totalPeriod: Int { hardware?.totalPeriod ?? 0 }

    /// The lights this Mac has, in menu order. Shortcuts and Link should only act on these.
    public var lights: [Light] { Light.allCases.filter(has) }

    public func has(_ light: Light) -> Bool {
        switch light {
        case .keyboard: return hardware != nil
        case .display: return display != nil
        }
    }
    public var levelIndex: Int { ladder.index(of: level) ?? 0 }

    private enum Keys {
        static let level = "level"
        static let followsInactivity = "followsInactivity"
        static let holdDuration = "holdDuration"
        static let autoBrightnessToRestore = "autoBrightnessToRestore"
        static let displayLevel = "displayLevel"
        /// The display's automatic brightness as found before the first shade; present only while
        /// on shades, so a crash on a shade leaves it for the next launch to hand back.
        static let displayAutoBrightnessToRestore = "displayAutoBrightnessToRestore"
    }

    /// The keyboard backlight; nil if this Mac has none KeyDimmer can drive.
    @ObservationIgnored private let hardware: BacklightHardware?
    @ObservationIgnored private let display: DisplayHardware?
    /// Whether the display's gamma table is one of our shades.
    @ObservationIgnored private var displayIsShaded = false
    /// Bundle identifiers of the other gamma apps running, oldest first; one entry per instance.
    @ObservationIgnored private var runningGammaApps: [String] = []
    /// The shade taken off for sleep, to put back on wake.
    @ObservationIgnored private var displaySleepingShade: Level?
    @ObservationIgnored private var displayWake: Cancellable?
    @ObservationIgnored private let clock: EngineClock
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let secondsSinceLastInput: () -> TimeInterval
    @ObservationIgnored private let floorKey: String
    @ObservationIgnored private let floorBuildKey: String
    @ObservationIgnored private let osBuild: String

    @ObservationIgnored private var engine: HoldEngine?
    @ObservationIgnored private var tuning = HoldEngine.Tuning()
    @ObservationIgnored private var monitorTimer: Cancellable?
    @ObservationIgnored private var statsTimer: Cancellable?
    /// Keeps App Nap from coalescing the hold timers, which otherwise fire hundreds of ms late.
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// macOS's inactivity timeout, captured before holding (see `BacklightHardware.idleDimTime`).
    @ObservationIgnored private var idleLimit: TimeInterval = 0

    /// - Parameters:
    ///   - hardware: the keyboard backlight, or nil if this Mac has none KeyDimmer can drive.
    ///   - display: the built-in display, or nil if this Mac has none KeyDimmer can drive.
    ///   - secondsSinceLastInput: time since the user last touched any input device.
    ///   - hardwareModel, osBuild: identify this Mac and macOS build for the floor cache.
    public init(
        hardware: BacklightHardware?, display: DisplayHardware? = nil, clock: EngineClock, store: SettingsStore,
        secondsSinceLastInput: @escaping () -> TimeInterval,
        hardwareModel: String = FloorProbe.hardwareModel, osBuild: String = FloorProbe.osBuild
    ) {
        self.hardware = hardware
        self.display = display
        displayLadder = display.map { _ in Ladder.display() }
        self.clock = clock
        self.store = store
        self.secondsSinceLastInput = secondsSinceLastInput
        floorKey = FloorProbe.cacheKey(model: hardwareModel)
        floorBuildKey = floorKey + ".osBuild"
        self.osBuild = osBuild
        followsInactivity = store.object(forKey: Keys.followsInactivity) as? Bool ?? true
        if let duration = store.object(forKey: Keys.holdDuration) as? Double { tuning.holdDuration = duration }
        // Placeholder so `cachedFloor()` can run; replaced on the next line.
        ladder = Ladder(floorPWM: 54)
        let floor = cachedFloor()
        ladder = Ladder(floorPWM: floor ?? 54)
        floorIsMeasured = floor != nil
    }

    // MARK: - Lifecycle

    /// Puts right what a crash may have left behind, then returns to the saved ember or shows
    /// whatever macOS is at.
    public func start() {
        startKeyboard()
        startDisplay()
    }

    private func startKeyboard() {
        guard let hardware else { return }
        restoreAutoBrightnessAfterCrash()
        if let saved = (store.object(forKey: Keys.level) as? String).flatMap(decode), saved.isEmber {
            select(saved)
        } else {
            level = ladder.nearestLevel(forBrightness: hardware.brightness())
        }
    }

    /// Leaves the keyboard as dim as macOS can keep it without us, and hands features back.
    public func willQuit() {
        quitKeyboard()
        quitDisplay()
    }

    private func quitKeyboard() {
        guard let hardware else { return }
        engine?.stop()
        if level.isEmber {
            hardware.setBrightness(HoldEngine.Tuning().floorGoal, fadeSpeed: 350, commit: true)
        }
        releaseSystemFeatures()
    }

    // MARK: - Selection

    /// The light's ladder; nil if this Mac doesn't have the light.
    public func ladder(of light: Light) -> Ladder? {
        switch light {
        case .keyboard: return hardware == nil ? nil : ladder
        case .display: return displayLadder
        }
    }

    /// The light's current level; nil if this Mac doesn't have the light.
    public func level(of light: Light) -> Level? {
        switch light {
        case .keyboard: return hardware == nil ? nil : level
        case .display: return displayLevel
        }
    }

    public func select(_ level: Level, on light: Light) {
        switch light {
        case .keyboard: select(level)
        case .display: selectDisplay(level)
        }
    }

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

    public func select(_ newLevel: Level) {
        // A probe in flight owns the backlight; it re-selects the level when it finishes.
        guard let hardware, !isCalibrating, !newLevel.isShade else { return }
        trace("select \(newLevel.title)")
        level = newLevel
        store.set(encode(newLevel), forKey: Keys.level)
        pause = nil

        switch newLevel {
        case .off:
            stopHolding()
            hardware.setBrightness(0, fadeSpeed: 350, commit: true)
            releaseSystemFeatures()
        case let .system(step):
            stopHolding()
            hardware.setBrightness(Level.systemBrightness(step: step), fadeSpeed: 350, commit: true)
            releaseSystemFeatures()
        case let .ember(index, _):
            takeOverSystemFeatures()
            withFloor { [weak self] in
                guard let self, self.level.isEmber else { return }
                // The ladder may have been rebuilt from a fresh floor measurement.
                guard let ember = self.ladder.ember(index), case let .ember(_, pwm) = ember else { return }
                self.level = ember
                self.startHolding(pwm: pwm)
            }
        case .shade:
            break // The keyboard has no shades (guarded above).
        }
    }

    // MARK: - Display

    /// The display's floor: the dimmest macOS step. Shades are applied on top of it.
    private static let displayFloor = Level.systemBrightness(step: 1)

    /// Returns to the saved shade (macOS restored the picture when the last run ended), or shows
    /// the step macOS is at.
    private func startDisplay() {
        guard let display, let displayLadder else { return }
        display.observeBrightness { [weak self, clock] _ in
            _ = clock.after(0) { self?.displayBrightnessChanged() }
        }
        let saved = (store.object(forKey: Keys.displayLevel) as? String).flatMap(displayLadder.level(named:))
        // A crash on a shade left automatic brightness paused, unless we're returning to a shade.
        if saved?.isShade != true { releaseDisplayAutoBrightness() }
        if let saved, saved.isShade {
            // Another gamma app is already running: the shade stands down to the floor, as it would have.
            selectDisplay(shadesUnavailableReason == nil ? saved : .system(step: 1))
        } else {
            displayLevel = displayLadder.nearestLevel(forBrightness: display.brightness())
        }
    }

    /// Leaves the display as dim as macOS can keep it without us: the floor, with the picture back.
    private func quitDisplay() {
        guard displayLevel?.isShade == true else { return }
        restoreDisplayGamma()
        setDisplayBrightness(Self.displayFloor)
        releaseDisplayAutoBrightness()
    }

    private func selectDisplay(_ newLevel: Level) {
        guard let displayLadder, displayLadder.index(of: newLevel) != nil,
              !(newLevel.isShade && shadesUnavailableReason != nil) else { return }
        trace("select display \(newLevel.title)")
        displayLevel = newLevel
        store.set(newLevel.storageName, forKey: Keys.displayLevel)
        applyDisplay(newLevel)
    }

    /// Drives the display to a level: a shade is the floor with the picture darkened, a system step
    /// is macOS's own brightness with the picture as ColorSync wants it.
    private func applyDisplay(_ level: Level) {
        switch level {
        case let .shade(_, factor):
            // Automatic brightness would move the backlight off the floor under the shade.
            takeOverDisplayAutoBrightness()
            setDisplayBrightness(Self.displayFloor)
            display?.setGamma(factor: factor)
            displayIsShaded = true
        case let .system(step):
            restoreDisplayGamma()
            setDisplayBrightness(Level.systemBrightness(step: step))
            releaseDisplayAutoBrightness()
        case .off, .ember:
            break // Not on the display's ladder.
        }
    }

    /// Only commands a change, so moving between shades leaves the backlight alone.
    private func setDisplayBrightness(_ value: Float) {
        guard let display, display.brightness() != value else { return }
        display.setBrightness(value)
    }

    /// Only touches the gamma if a shade of ours is applied: any other table (ColorSync's, or
    /// another app's) is left as it is.
    private func restoreDisplayGamma() {
        guard displayIsShaded else { return }
        display?.restoreGamma()
        displayIsShaded = false
    }

    /// macOS reports every brightness change, possibly including our own sets, and a stale echo
    /// can arrive after we've moved on, so the display's brightness right now is what counts, not
    /// the reported value. On a shade, anything but the floor means someone else (the brightness
    /// keys, Control Center, another app) took over: step aside and follow them. On a system step,
    /// the slider just follows.
    private func displayBrightnessChanged() {
        guard let display, let displayLadder, let displayLevel else { return }
        let brightness = display.brightness()
        trace("display brightness notification \(brightness)")
        let level = displayLadder.nearestLevel(forBrightness: brightness)
        if displayLevel.isShade {
            guard abs(brightness - Self.displayFloor) > 0.001 else { return }
            restoreDisplayGamma()
            releaseDisplayAutoBrightness()
        } else if level == displayLevel {
            return
        }
        self.displayLevel = level
        store.set(level.storageName, forKey: Keys.displayLevel)
    }

    /// Remembers automatic brightness as first found, so moving between shades keeps the original.
    private func takeOverDisplayAutoBrightness() {
        guard let display else { return }
        if store.object(forKey: Keys.displayAutoBrightnessToRestore) == nil {
            store.set(display.isAutoBrightnessEnabled, forKey: Keys.displayAutoBrightnessToRestore)
        }
        display.setAutoBrightness(false)
    }

    private func releaseDisplayAutoBrightness() {
        guard let display, let auto = store.object(forKey: Keys.displayAutoBrightnessToRestore) as? Bool else { return }
        display.setAutoBrightness(auto)
        store.removeObject(forKey: Keys.displayAutoBrightnessToRestore)
    }

    /// Takes the shade off for sleep, remembering it so waking can put it back.
    private func sleepDisplay() {
        displayWake?.cancel()
        displayWake = nil
        guard let displayLevel, displayLevel.isShade else { return }
        trace("sleep display")
        restoreDisplayGamma()
        displaySleepingShade = displayLevel
    }

    /// Puts the shade back after the wake grace, unless the level changed in the meantime.
    private func wakeDisplay() {
        guard displaySleepingShade != nil else { return }
        displayWake?.cancel()
        displayWake = clock.after(Self.wakeGrace) { [weak self] in
            guard let self, let shade = self.displaySleepingShade else { return }
            self.displaySleepingShade = nil
            self.displayWake = nil
            guard self.displayLevel == shade else { return }
            self.trace("wake display")
            self.applyDisplay(shade)
        }
    }

    // MARK: - Conflicting gamma apps

    /// Another gamma app (`GammaApps`) was launched, or was running when KeyDimmer started. Any
    /// shade is removed, leaving the display at its floor, and shades stay unavailable until it quits.
    public func otherGammaAppLaunched(bundleIdentifier: String) {
        guard GammaApps.name(forBundleIdentifier: bundleIdentifier) != nil else { return }
        trace("gamma app launched \(bundleIdentifier)")
        runningGammaApps.append(bundleIdentifier)
        updateShadesUnavailableReason()
        if displayLevel?.isShade == true { selectDisplay(.system(step: 1)) }
    }

    /// A gamma app quit. Once none is left, shades can be selected again; the display stays where it is.
    public func otherGammaAppQuit(bundleIdentifier: String) {
        guard let index = runningGammaApps.firstIndex(of: bundleIdentifier) else { return }
        trace("gamma app quit \(bundleIdentifier)")
        runningGammaApps.remove(at: index)
        updateShadesUnavailableReason()
    }

    private func updateShadesUnavailableReason() {
        shadesUnavailableReason = runningGammaApps.first
            .flatMap(GammaApps.name(forBundleIdentifier:))
            .map { "\($0) is running" }
    }

    // MARK: - Floor

    /// The measured floor, unless it was taken on another macOS build.
    private func cachedFloor() -> Int? {
        guard store.object(forKey: floorBuildKey) as? String == osBuild,
              let floor = store.object(forKey: floorKey) as? Int, floor >= FloorProbe.minimumPlausibleFloor
        else { return nil }
        return floor
    }

    private func withFloor(_ then: @escaping () -> Void) {
        if cachedFloor() != nil { return then() }
        measureFloor { _ in then() }
    }

    /// Keeps the previous floor if the measurement fails.
    private func measureFloor(_ completion: @escaping (Bool) -> Void) {
        guard let hardware else { return completion(false) }
        isCalibrating = true
        FloorProbe.measure(hardware: hardware, clock: clock) { [weak self] floor in
            guard let self else { return }
            self.isCalibrating = false
            if let floor {
                self.store.set(floor, forKey: self.floorKey)
                self.store.set(self.osBuild, forKey: self.floorBuildKey)
                self.ladder = Ladder(floorPWM: floor)
                self.floorIsMeasured = true
            }
            completion(floor != nil)
        }
    }

    /// Measures the floor again, then returns to the current level on the (possibly rebuilt) ladder.
    public func recalibrate() {
        guard hardware != nil, !isCalibrating else { return }
        trace("recalibrate")
        stopHolding()
        // Auto-brightness or idle dimming fading mid-probe would spoil the reading.
        takeOverSystemFeatures()
        calibrationFailed = false
        measureFloor { [weak self] success in
            guard let self else { return }
            self.calibrationFailed = !success
            self.select(self.level)
        }
    }

    // MARK: - Holding

    private func startHolding(pwm: Int) {
        guard let hardware else { return }
        if engine == nil || engine?.floorPWM != ladder.floorPWM {
            engine?.stop()
            let engine = HoldEngine(hardware: hardware, clock: clock, floorPWM: ladder.floorPWM, tuning: tuning)
            engine.onTuningChange = { [weak self] tuning in
                self?.tuning = tuning
                self?.store.set(tuning.holdDuration, forKey: Keys.holdDuration)
            }
            engine.onFailure = { message in NSLog("KeyDimmer: \(message)") }
            engine.onTrace = { [weak self] in self?.trace($0) }
            self.engine = engine
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Holding the keyboard backlight below the macOS minimum"
            )
        }
        engine?.hold(pwm: pwm)
        scheduleMonitor()
        scheduleStatsRefresh()
    }

    private func stopHolding() {
        engine?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        monitorTimer?.cancel()
        monitorTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
    }

    /// Auto-brightness and idle dimming would issue their own fades and break a hold.
    private func takeOverSystemFeatures() {
        guard let hardware else { return }
        if engine?.phase != .holding { idleLimit = hardware.idleDimTime() }
        if store.object(forKey: Keys.autoBrightnessToRestore) == nil {
            store.set(hardware.isAutoBrightnessEnabled, forKey: Keys.autoBrightnessToRestore)
        }
        hardware.setAutoBrightness(false)
        hardware.setIdleDimmingSuspended(true)
    }

    private func releaseSystemFeatures() {
        guard let hardware else { return }
        hardware.setIdleDimmingSuspended(false)
        if let auto = store.object(forKey: Keys.autoBrightnessToRestore) as? Bool {
            hardware.setAutoBrightness(auto)
            store.removeObject(forKey: Keys.autoBrightnessToRestore)
        }
    }

    private func restoreAutoBrightnessAfterCrash() {
        let saved = (store.object(forKey: Keys.level) as? String).flatMap(decode)
        if saved?.isEmber != true { releaseSystemFeatures() }
    }

    // MARK: - Pauses

    /// While an ember is selected: pause while the lid is closed and after the user's inactivity timeout.
    private func scheduleMonitor() {
        monitorTimer?.cancel()
        let interval: TimeInterval = pause == .inactive ? 0.25 : 1
        monitorTimer = clock.after(interval) { [weak self] in self?.monitor() }
    }

    private func monitor() {
        guard let hardware, level.isEmber else { return }
        defer { scheduleMonitor() }
        if pause == .sleeping { return }

        if hardware.isLidClosed() {
            if pause != .lidClosed { pauseHolding(.lidClosed) }
            return
        }
        if followsInactivity, idleLimit > 0, secondsSinceLastInput() >= idleLimit {
            if pause != .inactive { pauseHolding(.inactive) }
            return
        }
        if pause != nil { resumeHolding() }
    }

    private func pauseHolding(_ reason: Pause) {
        trace("pause \(reason)")
        pause = reason
        engine?.stop()
        // A gentle fade out, like macOS does for inactivity.
        hardware?.setBrightness(0, fadeSpeed: reason == .inactive ? 2_000 : 0, commit: false)
    }

    private func resumeHolding() {
        trace("resume")
        pause = nil
        if case let .ember(_, pwm) = level { startHolding(pwm: pwm) }
    }

    /// How long after waking the lights wait before returning to their levels, giving
    /// CoreBrightness (and the display's own restore) a moment to settle first.
    private static let wakeGrace: TimeInterval = 1

    /// The Mac or its displays are going to sleep. Locking the screen is not sleep: a shade stays.
    public func willSleep() {
        sleepDisplay()
        guard level.isEmber else { return }
        pauseHolding(.sleeping)
    }

    /// The Mac or its displays woke up.
    public func didWake() {
        wakeDisplay()
        guard level.isEmber else { return }
        // Give CoreBrightness a moment to restore its own state first.
        _ = clock.after(Self.wakeGrace) { [weak self] in
            guard let self, self.pause == .sleeping else { return }
            self.resumeHolding()
        }
    }

    private func scheduleStatsRefresh() {
        statsTimer?.cancel()
        statsTimer = clock.after(1) { [weak self] in
            guard let self, let engine = self.engine else { return }
            self.stats = engine.stats
            if engine.phase != .idle { self.scheduleStatsRefresh() }
        }
    }

    // MARK: - Step-aside

    /// CoreBrightness reports every target change, including ours. Values other than the two hold
    /// goals while holding, or a different step otherwise, mean someone else (Control Center,
    /// another app) changed the keyboard brightness — step aside and follow it.
    public func brightnessChanged(to value: Float) {
        trace("brightness notification \(value)")
        if hardware == nil || isCalibrating { return }
        let floorGoal = HoldEngine.Tuning().floorGoal
        // Hold goals, plus the floor probe's stepping stone.
        let ownGoals: [Float] = [0, floorGoal, floorGoal * 2]
        if level.isEmber {
            if ownGoals.contains(value) { return }
            stopHolding()
            pause = nil
            level = ladder.nearestLevel(forBrightness: value)
            store.set(encode(level), forKey: Keys.level)
            releaseSystemFeatures()
            return
        }
        let current: Float = {
            switch level {
            case .off: return 0
            case let .system(step): return Level.systemBrightness(step: step)
            case .ember, .shade: return 0
            }
        }()
        if abs(value - current) > 0.001 {
            level = ladder.nearestLevel(forBrightness: value)
            store.set(encode(level), forKey: Keys.level)
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard let onTrace else { return }
        onTrace(String(format: "%.3f ", clock.now) + message())
    }

    // MARK: - Persistence

    private func encode(_ level: Level) -> String { level.storageName }

    /// Reads a keyboard level name ("off", "ember:3", "system:8") on this controller's ladder.
    public func decode(_ string: String) -> Level? { ladder.level(named: string) }
}
