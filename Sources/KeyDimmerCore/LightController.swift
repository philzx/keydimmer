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
    ///
    /// Every change of the display's level, whoever causes it, passes through here, so this is
    /// where the Link makes the keyboard follow. The first reading at launch isn't a change.
    public private(set) var displayLevel: Level? {
        didSet { if oldValue != nil, displayLevel != oldValue { followDisplay() } }
    }
    /// Why the display's shades can't be selected right now, as the menu shows it ("Shades are off
    /// while Tint is running"), or nil.
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

    public func has(_ light: Light) -> Bool {
        switch light {
        case .keyboard: return keyboard != nil
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
        static let isLinked = "isLinked"
        /// The display's automatic brightness as found before the first shade; present only while
        /// on shades, so a crash on a shade leaves it for the next launch to hand back.
        static let displayAutoBrightnessToRestore = "displayAutoBrightnessToRestore"
    }

    /// The keyboard backlight; nil if this Mac has none KeyDimmer can drive.
    @ObservationIgnored private let keyboard: BacklightHardware?
    @ObservationIgnored private let display: DisplayHardware?
    /// Whether the display's gamma table is one of our shades.
    @ObservationIgnored private var displayIsShaded = false
    /// The other gamma apps running, oldest first; one entry per instance.
    @ObservationIgnored private var runningGammaApps: [(bundleIdentifier: String, name: String)] = []
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
    ///   - keyboard: the keyboard backlight, or nil if this Mac has none KeyDimmer can drive.
    ///   - display: the built-in display, or nil if this Mac has none KeyDimmer can drive.
    ///   - secondsSinceLastInput: time since the user last touched any input device.
    ///   - hardwareModel, osBuild: identify this Mac and macOS build for the floor cache.
    public init(
        keyboard: BacklightHardware?, display: DisplayHardware? = nil, clock: EngineClock, store: SettingsStore,
        secondsSinceLastInput: @escaping () -> TimeInterval,
        hardwareModel: String = FloorProbe.hardwareModel, osBuild: String = FloorProbe.osBuild
    ) {
        self.keyboard = keyboard
        self.display = display
        displayLadder = display.map { _ in Ladder.display() }
        self.clock = clock
        self.store = store
        self.secondsSinceLastInput = secondsSinceLastInput
        floorKey = FloorProbe.cacheKey(model: hardwareModel)
        floorBuildKey = floorKey + ".osBuild"
        self.osBuild = osBuild
        followsInactivity = store.object(forKey: Keys.followsInactivity) as? Bool ?? true
        linkSetting = store.object(forKey: Keys.isLinked) as? Bool ?? false
        if let duration = store.object(forKey: Keys.holdDuration) as? Double { tuning.holdDuration = duration }
        // Placeholder so `cachedFloor()` can run; replaced on the next line.
        ladder = Ladder(floorPWM: Ladder.assumedFloorPWM)
        let floor = cachedFloor()
        ladder = Ladder(floorPWM: floor ?? Ladder.assumedFloorPWM)
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
        guard let keyboard else { return }
        restoreAutoBrightnessAfterCrash()
        if let saved = (store.object(forKey: Keys.level) as? String).flatMap(decode), saved.isEmber {
            select(saved)
        } else {
            level = ladder.nearestLevel(forBrightness: keyboard.brightness())
        }
    }

    /// Leaves the keyboard as dim as macOS can keep it without us, and hands features back.
    public func willQuit() {
        quitKeyboard()
        quitDisplay()
    }

    private func quitKeyboard() {
        guard let keyboard else { return }
        engine?.stop()
        if level.isEmber {
            keyboard.setBrightness(HoldEngine.Tuning().floorGoal, fadeSpeed: 350, commit: true)
        }
        releaseSystemFeatures()
    }

    // MARK: - Selection

    /// The light's ladder; nil if this Mac doesn't have the light.
    public func ladder(of light: Light) -> Ladder? {
        switch light {
        case .keyboard: return keyboard == nil ? nil : ladder
        case .display: return displayLadder
        }
    }

    /// The light's current level; nil if this Mac doesn't have the light.
    public func level(of light: Light) -> Level? {
        switch light {
        case .keyboard: return keyboard == nil ? nil : level
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
        guard let keyboard, !isCalibrating, !newLevel.isShade else { return }
        trace("select \(newLevel.title)")
        level = newLevel
        store.set(newLevel.storageName, forKey: Keys.level)
        pause = nil

        switch newLevel {
        case .off:
            stopHolding()
            keyboard.setBrightness(0, fadeSpeed: 350, commit: true)
            releaseSystemFeatures()
        case let .system(step):
            stopHolding()
            keyboard.setBrightness(Level.systemBrightness(step: step), fadeSpeed: 350, commit: true)
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
    private static let displayFloor = Level.system(step: 1)
    private static let displayFloorBrightness = Level.systemBrightness(step: 1)

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
            selectDisplay(shadesUnavailableReason == nil ? saved : Self.displayFloor)
        } else {
            displayLevel = displayLadder.nearestLevel(forBrightness: display.brightness())
        }
    }

    /// Leaves the display as dim as macOS can keep it without us: the floor, with the picture back.
    private func quitDisplay() {
        guard displayLevel?.isShade == true else { return }
        restoreDisplayGamma()
        setDisplayBrightness(Self.displayFloorBrightness)
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
            setDisplayBrightness(Self.displayFloorBrightness)
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
    /// the slider just follows. While the shade is off for sleep, until the wake grace is over,
    /// macOS and the panel move the brightness themselves, so ignore it: the wake puts
    /// the shade back on the floor.
    private func displayBrightnessChanged() {
        guard let display, let displayLadder, let displayLevel, displaySleepingShade == nil else { return }
        let brightness = display.brightness()
        trace("display brightness notification \(brightness)")
        let level = displayLadder.nearestLevel(forBrightness: brightness)
        if displayLevel.isShade {
            guard abs(brightness - Self.displayFloorBrightness) > 0.001 else { return }
            restoreDisplayGamma()
            releaseDisplayAutoBrightness()
        } else if level == displayLevel {
            return
        }
        self.displayLevel = level
        store.set(level.storageName, forKey: Keys.displayLevel)
    }

    private func takeOverDisplayAutoBrightness() {
        guard let display else { return }
        takeOverAutoBrightness(recordedAt: Keys.displayAutoBrightnessToRestore,
                               isEnabled: display.isAutoBrightnessEnabled, set: display.setAutoBrightness)
    }

    /// Without a display to drive, the record stays for a launch (or `builtInDisplayAppeared(_:)`) that has one.
    private func releaseDisplayAutoBrightness(on display: DisplayHardware? = nil) {
        guard let display = display ?? self.display else { return }
        handBackAutoBrightness(recordedAt: Keys.displayAutoBrightnessToRestore, set: display.setAutoBrightness)
    }

    /// The built-in display came online while running without it (the lid opened in clamshell
    /// mode). This run doesn't drive it, but automatic brightness that a crash on a shade left
    /// paused is handed back now rather than at the next launch.
    public func builtInDisplayAppeared(_ builtIn: DisplayHardware) {
        guard display == nil else { return }
        trace("built-in display appeared")
        releaseDisplayAutoBrightness(on: builtIn)
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

    /// Another gamma app (the app layer matches `GammaApps`) was launched, or was running when
    /// KeyDimmer started. Any shade is removed, leaving the display at its floor, and shades stay
    /// unavailable until it quits.
    public func otherGammaAppLaunched(bundleIdentifier: String, name: String) {
        trace("gamma app launched \(bundleIdentifier)")
        runningGammaApps.append((bundleIdentifier, name))
        updateShadesUnavailableReason()
        if displayLevel?.isShade == true { selectDisplay(Self.displayFloor) }
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
        guard let keyboard else { return completion(false) }
        isCalibrating = true
        FloorProbe.measure(hardware: keyboard, clock: clock) { [weak self] floor in
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
        guard keyboard != nil, !isCalibrating else { return }
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
        guard let keyboard else { return }
        if engine == nil || engine?.floorPWM != ladder.floorPWM {
            engine?.stop()
            let engine = HoldEngine(hardware: keyboard, clock: clock, floorPWM: ladder.floorPWM, tuning: tuning)
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
                reason: "Holding the keyboard backlight on an ember, below its floor"
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
        guard let keyboard else { return }
        if engine?.phase != .holding { idleLimit = keyboard.idleDimTime() }
        takeOverAutoBrightness(recordedAt: Keys.autoBrightnessToRestore,
                               isEnabled: keyboard.isAutoBrightnessEnabled, set: keyboard.setAutoBrightness)
        keyboard.setIdleDimmingSuspended(true)
    }

    private func releaseSystemFeatures() {
        guard let keyboard else { return }
        keyboard.setIdleDimmingSuspended(false)
        handBackAutoBrightness(recordedAt: Keys.autoBrightnessToRestore, set: keyboard.setAutoBrightness)
    }

    // MARK: - Automatic brightness (either light)

    /// Turns a light's automatic brightness off, recording under `key` how it was first found, so
    /// moving between embers or shades keeps the original. The record is persisted, so a crash
    /// leaves it for the next launch to hand back.
    private func takeOverAutoBrightness(recordedAt key: String, isEnabled: Bool, set: (Bool) -> Void) {
        if store.object(forKey: key) == nil { store.set(isEnabled, forKey: key) }
        set(false)
    }

    /// Puts a light's automatic brightness back as recorded under `key` and clears the record;
    /// does nothing without a record.
    private func handBackAutoBrightness(recordedAt key: String, set: (Bool) -> Void) {
        guard let auto = store.object(forKey: key) as? Bool else { return }
        set(auto)
        store.removeObject(forKey: key)
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
        guard let keyboard, level.isEmber else { return }
        defer { scheduleMonitor() }
        if pause == .sleeping { return }

        if keyboard.isLidClosed() {
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
        keyboard?.setBrightness(0, fadeSpeed: reason == .inactive ? 2_000 : 0, commit: false)
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

    /// CoreBrightness reports every target change, including ours, and a stale echo of a previous
    /// selection can arrive after we've moved on (the hold engine's 0 after leaving an ember, the
    /// dimmest step after entering one). So, like the display, the target CoreBrightness holds
    /// right now is what counts, not the reported value. A target other than the hold goals while
    /// holding, or a different step otherwise, means someone else (Control Center, another app)
    /// changed the keyboard brightness — step aside and follow it.
    public func brightnessChanged(to value: Float) {
        trace("brightness notification \(value)")
        guard let keyboard, !isCalibrating else { return }
        let brightness = keyboard.brightness()
        let floorGoal = HoldEngine.Tuning().floorGoal
        // Hold goals, plus the floor probe's stepping stone.
        let ownGoals: [Float] = [0, floorGoal, floorGoal * 2]
        if level.isEmber {
            if ownGoals.contains(brightness) { return }
            stopHolding()
            pause = nil
            level = ladder.nearestLevel(forBrightness: brightness)
            store.set(level.storageName, forKey: Keys.level)
            releaseSystemFeatures()
            return
        }
        let current: Float = {
            switch level {
            case let .system(step): return Level.systemBrightness(step: step)
            case .off, .ember, .shade: return 0
            }
        }()
        if abs(brightness - current) > 0.001 {
            level = ladder.nearestLevel(forBrightness: brightness)
            store.set(level.storageName, forKey: Keys.level)
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
