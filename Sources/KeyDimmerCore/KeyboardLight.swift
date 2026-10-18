import Foundation
import Observation

/// The keyboard backlight's state and rules: the ladder from its measured floor, holding an ember,
/// pausing the hold (sleep, closed lid, inactivity) and stepping aside when someone else changes
/// the brightness. `LightController` routes commands and events here.
@Observable
final class KeyboardLight {
    private(set) var ladder: Ladder
    private(set) var level: Level = .off
    private(set) var pause: LightController.Pause?
    private(set) var stats = HoldEngine.Stats()
    private(set) var isCalibrating = false
    /// Whether the ladder comes from a measurement on this Mac and macOS build.
    private(set) var floorIsMeasured: Bool
    /// The last recalibration could not measure the floor.
    private(set) var calibrationFailed = false

    /// Whether an ember turns off after macOS's keyboard inactivity timeout, as macOS's own levels do.
    var followsInactivity: Bool {
        didSet { store.set(followsInactivity, forKey: Keys.followsInactivity) }
    }

    @ObservationIgnored var onTrace: ((String) -> Void)?

    var totalPeriod: Int { hardware.totalPeriod }

    enum Keys {
        static let level = "level"
        static let followsInactivity = "followsInactivity"
        static let holdDuration = "holdDuration"
        static let autoBrightnessToRestore = "autoBrightnessToRestore"
    }

    @ObservationIgnored private let hardware: BacklightHardware
    @ObservationIgnored private let clock: EngineClock
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let floorCache: FloorCache
    @ObservationIgnored private let autoBrightness: AutoBrightnessRecord
    @ObservationIgnored private let secondsSinceLastInput: () -> TimeInterval

    @ObservationIgnored private var engine: HoldEngine?
    @ObservationIgnored private var tuning = HoldEngine.Tuning()
    @ObservationIgnored private var monitorTimer: Cancellable?
    @ObservationIgnored private var statsTimer: Cancellable?
    /// Keeps App Nap from coalescing the hold timers, which otherwise fire hundreds of ms late.
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// macOS's inactivity timeout, captured before holding (see `BacklightHardware.idleDimTime`).
    @ObservationIgnored private var idleLimit: TimeInterval = 0

    init(
        hardware: BacklightHardware, clock: EngineClock, store: SettingsStore, floorCache: FloorCache,
        secondsSinceLastInput: @escaping () -> TimeInterval
    ) {
        self.hardware = hardware
        self.clock = clock
        self.store = store
        self.floorCache = floorCache
        autoBrightness = AutoBrightnessRecord(store: store, key: Keys.autoBrightnessToRestore)
        self.secondsSinceLastInput = secondsSinceLastInput
        followsInactivity = Self.followsInactivity(in: store)
        if let duration = store.object(forKey: Keys.holdDuration) as? Double { tuning.holdDuration = duration }
        let floor = floorCache.floor
        ladder = Ladder(floorPWM: floor ?? Ladder.assumedFloorPWM)
        floorIsMeasured = floor != nil
    }

    /// The saved inactivity setting, for a controller without a keyboard to read it from.
    static func followsInactivity(in store: SettingsStore) -> Bool {
        store.object(forKey: Keys.followsInactivity) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Puts right what a crash may have left behind, then returns to the saved ember or shows
    /// whatever macOS is at.
    func start() {
        restoreAutoBrightnessAfterCrash()
        if let saved = (store.object(forKey: Keys.level) as? String).flatMap(decode), saved.isEmber {
            select(saved)
        } else {
            level = ladder.nearestLevel(forBrightness: hardware.brightness())
        }
    }

    /// Leaves the keyboard as dim as macOS can keep it without us, and hands features back.
    func willQuit() {
        engine?.stop()
        if level.isEmber {
            hardware.setBrightness(HoldEngine.Tuning().floorGoal, fadeSpeed: 350, commit: true)
        }
        releaseSystemFeatures()
    }

    // MARK: - Selection

    func select(_ newLevel: Level) {
        // A probe in flight owns the backlight; it re-selects the level when it finishes.
        guard !isCalibrating, !newLevel.isShade else { return }
        trace("select \(newLevel.title)")
        level = newLevel
        store.set(newLevel.storageName, forKey: Keys.level)
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

    // MARK: - Floor

    private func withFloor(_ then: @escaping () -> Void) {
        if floorCache.floor != nil { return then() }
        measureFloor { _ in then() }
    }

    /// Keeps the previous floor if the measurement fails.
    private func measureFloor(_ completion: @escaping (Bool) -> Void) {
        isCalibrating = true
        FloorProbe.measure(hardware: hardware, clock: clock) { [weak self] floor in
            guard let self else { return }
            self.isCalibrating = false
            if let floor {
                self.floorCache.save(floor)
                self.ladder = Ladder(floorPWM: floor)
                self.floorIsMeasured = true
            }
            completion(floor != nil)
        }
    }

    /// Measures the floor again, then returns to the current level on the (possibly rebuilt) ladder.
    func recalibrate() {
        guard !isCalibrating else { return }
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
        if engine?.phase != .holding { idleLimit = hardware.idleDimTime() }
        autoBrightness.takeOver(isEnabled: hardware.isAutoBrightnessEnabled, set: hardware.setAutoBrightness)
        hardware.setIdleDimmingSuspended(true)
    }

    private func releaseSystemFeatures() {
        hardware.setIdleDimmingSuspended(false)
        autoBrightness.handBack(set: hardware.setAutoBrightness)
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
        guard level.isEmber else { return }
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

    private func pauseHolding(_ reason: LightController.Pause) {
        trace("pause \(reason)")
        pause = reason
        engine?.stop()
        // A gentle fade out, like macOS does for inactivity.
        hardware.setBrightness(0, fadeSpeed: reason == .inactive ? 2_000 : 0, commit: false)
    }

    private func resumeHolding() {
        trace("resume")
        pause = nil
        if case let .ember(_, pwm) = level { startHolding(pwm: pwm) }
    }

    func willSleep() {
        guard level.isEmber else { return }
        pauseHolding(.sleeping)
    }

    func didWake() {
        guard level.isEmber else { return }
        // Give CoreBrightness a moment to restore its own state first.
        _ = clock.after(LightController.wakeGrace) { [weak self] in
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
    func brightnessChanged() {
        guard !isCalibrating else { return }
        let brightness = hardware.brightness()
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

    // MARK: - Persistence

    /// Reads a keyboard level name ("off", "ember:3", "system:8") on this light's ladder.
    func decode(_ string: String) -> Level? { ladder.level(named: string) }

    private func trace(_ message: @autoclosure () -> String) {
        guard let onTrace else { return }
        onTrace(message())
    }
}
