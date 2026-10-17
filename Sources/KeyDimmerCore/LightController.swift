import Foundation
import Observation

/// Where the controller keeps what must survive a relaunch. `UserDefaults` in the app.
public protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// Owns the keyboard light, its ladder and every rule about it.
///
/// It takes commands (select a level, step), receives events (macOS changed the brightness, will
/// sleep, did wake, will quit) and publishes the state the menu renders. It watches the lid and
/// the user's inactivity itself while holding an ember. Everything runs on the clock's queue.
@Observable
public final class LightController {
    public enum Pause: Equatable, Sendable {
        case sleeping
        case lidClosed
        case inactive
    }

    public private(set) var ladder: Ladder
    public private(set) var level: Level = .off
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

    public var totalPeriod: Int { hardware.totalPeriod }
    public var levelIndex: Int { ladder.index(of: level) ?? 0 }

    private enum Keys {
        static let level = "level"
        static let followsInactivity = "followsInactivity"
        static let holdDuration = "holdDuration"
        static let autoBrightnessToRestore = "autoBrightnessToRestore"
    }

    @ObservationIgnored private let hardware: BacklightHardware
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
    ///   - secondsSinceLastInput: time since the user last touched any input device.
    ///   - hardwareModel, osBuild: identify this Mac and macOS build for the floor cache.
    public init(
        hardware: BacklightHardware, clock: EngineClock, store: SettingsStore,
        secondsSinceLastInput: @escaping () -> TimeInterval,
        hardwareModel: String = FloorProbe.hardwareModel, osBuild: String = FloorProbe.osBuild
    ) {
        self.hardware = hardware
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
        restoreAutoBrightnessAfterCrash()
        if let saved = (store.object(forKey: Keys.level) as? String).flatMap(decode), saved.isEmber {
            select(saved)
        } else {
            level = ladder.nearestLevel(forBrightness: hardware.brightness())
        }
    }

    /// Leaves the keyboard as dim as macOS can keep it without us, and hands features back.
    public func willQuit() {
        engine?.stop()
        if level.isEmber {
            hardware.setBrightness(HoldEngine.Tuning().floorGoal, fadeSpeed: 350, commit: true)
        }
        releaseSystemFeatures()
    }

    // MARK: - Selection

    public func select(index: Int) { select(ladder.level(at: index)) }

    /// Does nothing at either end, where a held shortcut keeps repeating.
    public func step(by delta: Int) {
        let index = min(max(levelIndex + delta, 0), ladder.count - 1)
        if index != levelIndex { select(index: index) }
    }

    public func select(_ newLevel: Level) {
        // A probe in flight owns the backlight; it re-selects the level when it finishes.
        guard !isCalibrating else { return }
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
        if engine?.phase != .holding { idleLimit = hardware.idleDimTime() }
        if store.object(forKey: Keys.autoBrightnessToRestore) == nil {
            store.set(hardware.isAutoBrightnessEnabled, forKey: Keys.autoBrightnessToRestore)
        }
        hardware.setAutoBrightness(false)
        hardware.setIdleDimmingSuspended(true)
    }

    private func releaseSystemFeatures() {
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

    private func pauseHolding(_ reason: Pause) {
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

    /// The Mac or its displays are going to sleep.
    public func willSleep() {
        guard level.isEmber else { return }
        pauseHolding(.sleeping)
    }

    /// The Mac or its displays woke up.
    public func didWake() {
        guard level.isEmber else { return }
        // Give CoreBrightness a moment to restore its own state first.
        _ = clock.after(1) { [weak self] in
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
        if isCalibrating { return }
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
            case .ember: return 0
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

    private func encode(_ level: Level) -> String {
        switch level {
        case .off: return "off"
        case let .ember(index, _): return "ember:\(index)"
        case let .system(step): return "system:\(step)"
        }
    }

    /// Reads a level name ("off", "ember:3", "system:8") on this controller's ladder.
    public func decode(_ string: String) -> Level? {
        let parts = string.split(separator: ":")
        switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
        case ("off", _): return .off
        case let ("ember", index?): return ladder.ember(index)
        case let ("system", step?): return .system(step: min(max(step, 1), Ladder.systemSteps))
        default: return nil
        }
    }
}
