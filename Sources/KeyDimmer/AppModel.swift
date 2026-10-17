import AppKit
import CoreGraphics
import KeyDimmerCore
import Observation
import ServiceManagement

/// Owns the backlight, the hold engine and everything the menu shows.
@MainActor
@Observable
final class AppModel {
    enum Pause: Equatable {
        case sleeping
        case lidClosed
        case inactive
    }

    private(set) var ladder: Ladder
    private(set) var level: Level = .off
    private(set) var pause: Pause?
    private(set) var unsupportedReason: String?
    private(set) var stats = HoldEngine.Stats()
    private(set) var isCalibrating = false

    var hotkeysEnabled: Bool {
        didSet {
            defaults.set(hotkeysEnabled, forKey: Keys.hotkeys)
            hotKeys.isEnabled = hotkeysEnabled
        }
    }

    var followsInactivity: Bool {
        didSet { defaults.set(followsInactivity, forKey: Keys.followsInactivity) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("KeyDimmer: launch at login change failed: \(error)")
            }
            launchAtLoginRevision += 1
        }
    }
    /// Bumped so SwiftUI re-reads `launchAtLogin`, which lives outside this object.
    private(set) var launchAtLoginRevision = 0

    private enum Keys {
        static let level = "level"
        static let hotkeys = "hotkeysEnabled"
        static let followsInactivity = "followsInactivity"
        static let holdDuration = "holdDuration"
        static let autoBrightnessToRestore = "autoBrightnessToRestore"
    }

    private let defaults = UserDefaults.standard
    private let hardware: BacklightHardware?
    private let clock = DispatchClock()
    private var engine: HoldEngine?
    private var tuning = HoldEngine.Tuning()
    private let hotKeys = HotKeys()
    private var power: PowerObserver?
    private var monitorTimer: Cancellable?
    /// Keeps App Nap from coalescing the hold timers, which otherwise fire hundreds of ms late.
    private var activity: NSObjectProtocol?
    /// macOS's inactivity timeout, captured before holding (see `BacklightHardware.idleDimTime`).
    private var idleLimit: TimeInterval = 0
    private var statsTimer: Cancellable?

    init() {
        let defaults = UserDefaults.standard
        hotkeysEnabled = defaults.object(forKey: Keys.hotkeys) as? Bool ?? true
        followsInactivity = defaults.object(forKey: Keys.followsInactivity) as? Bool ?? true
        let floor = (defaults.object(forKey: FloorProbe.cacheKey(model: FloorProbe.hardwareModel)) as? Int)
            .flatMap { $0 >= FloorProbe.minimumPlausibleFloor ? $0 : nil }
        ladder = Ladder(floorPWM: floor ?? 54)

        var reason: String?
        do {
            hardware = try CoreBrightnessBacklight()
        } catch {
            hardware = nil
            reason = "\(error)"
        }
        if hardware?.readPWM() == nil, reason == nil {
            reason = "This Mac has no Apple Silicon keyboard backlight PWM"
        }
        unsupportedReason = reason
        if let duration = defaults.object(forKey: Keys.holdDuration) as? Double { tuning.holdDuration = duration }
    }

    var isSupported: Bool { unsupportedReason == nil }

    var levelIndex: Int { ladder.index(of: level) ?? 0 }

    var dutyDescription: String? {
        guard case let .ember(_, pwm) = level, let hardware else { return nil }
        return "\(pwm)/\(hardware.totalPeriod)"
    }

    // MARK: - Lifecycle

    func start() {
        guard let hardware, isSupported else { return }
        restoreAutoBrightnessAfterCrash()

        hardware.observeBrightness { [weak self] value in
            DispatchQueue.main.async { self?.brightnessChanged(to: value) }
        }
        hotKeys.onStep = { [weak self] delta in self?.step(by: delta) }
        hotKeys.isEnabled = hotkeysEnabled
        power = PowerObserver { [weak self] event in self?.powerEvent(event) }

        if let saved = defaults.string(forKey: Keys.level).flatMap(decode), saved.isEmber {
            select(saved)
        } else {
            level = ladder.nearestLevel(forBrightness: hardware.brightness())
        }
    }

    /// Leaves the keyboard as dim as macOS can keep it without us, and hands features back.
    func prepareForQuit() {
        guard let hardware else { return }
        engine?.stop()
        if level.isEmber {
            hardware.setBrightness(HoldEngine.Tuning().floorGoal, fadeSpeed: 350, commit: true)
        }
        releaseSystemFeatures()
    }

    // MARK: - Selection

    func select(index: Int) { select(ladder.level(at: index)) }

    func step(by delta: Int) { select(index: levelIndex + delta) }

    func select(_ newLevel: Level) {
        guard let hardware, isSupported else { return }
        trace("select \(newLevel.title)")
        level = newLevel
        defaults.set(encode(newLevel), forKey: Keys.level)
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

    // MARK: - Holding

    private func withFloor(_ then: @escaping () -> Void) {
        guard let hardware else { return }
        let key = FloorProbe.cacheKey(model: FloorProbe.hardwareModel)
        if let cached = defaults.object(forKey: key) as? Int, cached >= FloorProbe.minimumPlausibleFloor { return then() }
        isCalibrating = true
        FloorProbe.measure(hardware: hardware, clock: clock) { [weak self] floor in
            guard let self else { return }
            self.isCalibrating = false
            if let floor {
                self.defaults.set(floor, forKey: key)
                self.ladder = Ladder(floorPWM: floor)
            }
            then()
        }
    }

    private func startHolding(pwm: Int) {
        guard let hardware else { return }
        if engine == nil || engine?.floorPWM != ladder.floorPWM {
            engine?.stop()
            let engine = HoldEngine(hardware: hardware, clock: clock, floorPWM: ladder.floorPWM, tuning: tuning)
            engine.onTuningChange = { [weak self] tuning in
                self?.tuning = tuning
                self?.defaults.set(tuning.holdDuration, forKey: Keys.holdDuration)
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
        if defaults.object(forKey: Keys.autoBrightnessToRestore) == nil {
            defaults.set(hardware.isAutoBrightnessEnabled, forKey: Keys.autoBrightnessToRestore)
        }
        hardware.setAutoBrightness(false)
        hardware.setIdleDimmingSuspended(true)
    }

    private func releaseSystemFeatures() {
        guard let hardware else { return }
        hardware.setIdleDimmingSuspended(false)
        if let auto = defaults.object(forKey: Keys.autoBrightnessToRestore) as? Bool {
            hardware.setAutoBrightness(auto)
            defaults.removeObject(forKey: Keys.autoBrightnessToRestore)
        }
    }

    private func restoreAutoBrightnessAfterCrash() {
        let saved = defaults.string(forKey: Keys.level).flatMap(decode)
        if saved?.isEmber != true { releaseSystemFeatures() }
    }

    // MARK: - Monitoring

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
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        if followsInactivity, idleLimit > 0, idle >= idleLimit {
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

    private func powerEvent(_ event: PowerObserver.Event) {
        guard level.isEmber else { return }
        switch event {
        case .willSleep:
            pauseHolding(.sleeping)
        case .didWake:
            // Give CoreBrightness a moment to restore its own state first.
            _ = clock.after(1) { [weak self] in
                guard let self, self.pause == .sleeping else { return }
                self.resumeHolding()
            }
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

    /// CoreBrightness reports every target change, including ours. Values other than the two hold
    /// goals while holding, or a different step otherwise, mean someone else (Control Center,
    /// another app) changed the keyboard brightness — step aside and follow it.
    private func brightnessChanged(to value: Float) {
        trace("brightness notification \(value)")
        let floorGoal = HoldEngine.Tuning().floorGoal
        // Hold goals, plus the floor probe's stepping stone.
        let ownGoals: [Float] = [0, floorGoal, floorGoal * 2]
        if level.isEmber {
            if ownGoals.contains(value) { return }
            stopHolding()
            pause = nil
            level = ladder.nearestLevel(forBrightness: value)
            defaults.set(encode(level), forKey: Keys.level)
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
            defaults.set(encode(level), forKey: Keys.level)
        }
    }

    /// Shows a level without driving the hardware (snapshots only).
    func preview(levelNamed name: String) {
        if let previewLevel = decode(name) { level = previewLevel }
        stats.watchdogSamples = 100
        stats.watchdogHits = 100
    }

    private let tracing = ProcessInfo.processInfo.environment["KEYDIMMER_TRACE"] != nil

    private func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        print(String(format: "%.3f ", clock.now) + message())
        fflush(stdout)
    }

    // MARK: - Persistence

    private func encode(_ level: Level) -> String {
        switch level {
        case .off: return "off"
        case let .ember(index, _): return "ember:\(index)"
        case let .system(step): return "system:\(step)"
        }
    }

    private func decode(_ string: String) -> Level? {
        let parts = string.split(separator: ":")
        switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
        case ("off", _): return .off
        case let ("ember", index?): return ladder.ember(index)
        case let ("system", step?): return .system(step: min(max(step, 1), Ladder.systemSteps))
        default: return nil
        }
    }
}
