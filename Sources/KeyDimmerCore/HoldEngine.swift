import Foundation

/// Holds the keyboard backlight at a PWM duty below macOS's floor.
///
/// macOS clamps every non-zero brightness to a hardware floor, but a fade towards 0 passes through
/// every PWM count below it. Each `setBrightness(_:fadeSpeed:)` call starts a *linear* fade from the
/// current output to its goal over a duration that depends only on `fadeSpeed` (≈41 s at the slowest
/// speed), and a call with the same goal as the fade in flight is ignored.
///
/// The engine therefore:
/// 1. **Approaches** the target with a quick fade while polling the PWM every few milliseconds, and
///    syncs a model of the hidden fade position the moment the PWM crosses a known bucket edge.
/// 2. **Holds** by alternating very slow fades down (goal 0) and up (goal = floor), reversing when
///    the modelled position reaches ±`amplitude` around the centre of the target bucket. Because the
///    position never leaves the bucket, the integer PWM — and so the light — does not change.
/// 3. **Resyncs** whenever a watchdog read disagrees with the model, and adapts its estimate of the
///    slow fade duration from the direction of the error.
public final class HoldEngine {
    public struct Tuning: Equatable {
        public var holdFadeSpeed: Int32 = 500_000
        public var approachFadeSpeed: Int32 = 2_000
        /// Seconds a hold-speed fade takes regardless of distance. Adapted at runtime.
        public var holdDuration: TimeInterval = 41
        /// Seconds an approach-speed fade takes. Refined from observed crossings.
        public var approachDuration: TimeInterval = 2
        /// Half-width of the oscillation around the bucket centre, in PWM counts (< 0.5).
        public var amplitude: Double = 0.2
        public var approachPollInterval: TimeInterval = 0.004
        public var watchdogInterval: TimeInterval = 1
        public var approachTimeout: TimeInterval = 10
        /// Smallest non-zero brightness; macOS outputs its floor PWM for it.
        public var floorGoal: Float = 0.0005
        /// Multiplicative step applied to `holdDuration` on each modelling error.
        public var adaptationStep: Double = 0.02

        public init() {}
    }

    public enum Phase: Equatable {
        case idle
        case approaching
        case holding
    }

    public struct Stats: Equatable {
        public var reversals = 0
        public var resyncs = 0
        public var watchdogSamples = 0
        public var watchdogHits = 0
        public var lastPWM: Int?

        public init() {}

        /// Fraction of watchdog reads that found the PWM exactly on target.
        public var stability: Double {
            watchdogSamples == 0 ? 1 : Double(watchdogHits) / Double(watchdogSamples)
        }
    }

    private enum Direction { case down, up }

    /// The fade currently commanded, in PWM-count coordinates.
    private struct Fade {
        var direction: Direction
        var goalX: Double
        var startX: Double
        var startTime: TimeInterval
        var duration: TimeInterval
        var fadeSpeed: Int32

        var rate: Double { abs(goalX - startX) / duration }

        func position(at time: TimeInterval) -> Double {
            let progress = min(max((time - startTime) / duration, 0), 1)
            return startX + (goalX - startX) * progress
        }
    }

    private let hardware: BacklightHardware
    private let clock: EngineClock
    public let floorPWM: Int
    public private(set) var tuning: Tuning

    public private(set) var phase: Phase = .idle
    public private(set) var target: Int?
    public private(set) var stats = Stats()
    /// Fires on the clock's queue with the new tuning whenever adaptation changes it.
    public var onTuningChange: ((Tuning) -> Void)?
    /// Fires if the approach cannot reach the target (e.g. the PWM service stopped reporting).
    public var onFailure: ((String) -> Void)?
    /// Human-readable trace of syncs, reversals and drifts, for diagnostics.
    public var onTrace: ((String) -> Void)?

    private var fade: Fade?
    private var lastGoal: Float?
    private var lastSpeed: Int32?
    private var pendingTimer: Cancellable?
    private var watchdogTimer: Cancellable?

    // Approach bookkeeping.
    private var approachStart: TimeInterval = 0
    private var approachLastPWM = 0
    private var approachLastCrossing: TimeInterval?
    private var approachMeasuredRate: Double?
    private var syncThreshold = 0

    public init(hardware: BacklightHardware, clock: EngineClock, floorPWM: Int, tuning: Tuning = Tuning()) {
        self.hardware = hardware
        self.clock = clock
        self.floorPWM = floorPWM
        self.tuning = tuning
    }

    /// The brightness goal of the most recent command, so callers can tell KeyDimmer's own
    /// CoreBrightness notifications from someone else's.
    public var lastCommandedGoal: Float? { lastGoal }

    // MARK: - Public control

    public func hold(pwm requested: Int) {
        let newTarget = min(max(requested, 1), max(floorPWM - 1, 1))
        target = newTarget
        stats = Stats()
        if phase == .idle {
            // Whatever left the backlight here may have used the goal we are about to send; with
            // no known speed the first command always bounces.
            lastGoal = hardware.brightness()
            lastSpeed = nil
        }
        startApproach()
    }

    /// Stops commanding fades. The light keeps fading towards whatever the last command was.
    public func stop() {
        cancelTimers()
        phase = .idle
        target = nil
        fade = nil
    }

    /// Stops holding and turns the light off at `fadeSpeed`, even if the hold was already fading
    /// down towards 0 at its own, much slower, speed.
    public func fadeOut(fadeSpeed: Int32) {
        stop()
        // Bounce at the hold's own slow speed: overridden at once, it barely moves the light,
        // where an instant bounce up to the floor could flash before the light goes dark.
        send(0, speed: fadeSpeed, bounceSpeed: lastSpeed ?? fadeSpeed)
    }

    // MARK: - Commands

    /// Commands a fade to `goal`. Same goal as the fade in flight is ignored by CoreBrightness, so
    /// a new speed first bounces off the opposite goal (at `bounceSpeed`, by default the new one).
    private func send(_ goal: Float, speed: Int32, bounceSpeed: Int32? = nil) {
        if goal == lastGoal, speed != lastSpeed {
            let bounce: Float = goal == 0 ? tuning.floorGoal : 0
            hardware.setBrightness(bounce, fadeSpeed: bounceSpeed ?? speed, commit: false)
        }
        hardware.setBrightness(goal, fadeSpeed: speed, commit: false)
        lastGoal = goal
        lastSpeed = speed
    }

    private func command(_ direction: Direction, speed: Int32, from startX: Double, at time: TimeInterval) {
        send(direction == .down ? 0 : tuning.floorGoal, speed: speed)
        let duration = speed == tuning.holdFadeSpeed ? tuning.holdDuration : tuning.approachDuration
        fade = Fade(
            direction: direction,
            goalX: direction == .down ? 0 : Double(floorPWM),
            startX: startX,
            startTime: time,
            duration: duration,
            fadeSpeed: speed
        )
    }

    private func cancelTimers() {
        pendingTimer?.cancel()
        pendingTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Approach

    private func startApproach() {
        guard let target else { return }
        cancelTimers()
        guard let pwm = hardware.readPWM() else {
            phase = .idle
            onFailure?("The keyboard backlight PWM could not be read")
            return
        }
        phase = .approaching
        stats.lastPWM = pwm
        let now = clock.now
        approachStart = now
        approachLastPWM = pwm
        approachLastCrossing = nil
        approachMeasuredRate = nil

        let direction: Direction
        if pwm > target {
            direction = .down
            syncThreshold = target
        } else if pwm < target {
            direction = .up
            syncThreshold = target
        } else if target > 1 {
            // Already in the bucket but position unknown: step out of the lower edge to find it.
            direction = .down
            syncThreshold = target - 1
        } else {
            direction = .up
            syncThreshold = target + 1
        }
        command(direction, speed: tuning.approachFadeSpeed, from: Double(pwm) + 0.5, at: now)
        pendingTimer = clock.after(tuning.approachPollInterval) { [weak self] in self?.pollApproach() }
    }

    private func pollApproach() {
        guard phase == .approaching, let fade else { return }
        let now = clock.now
        guard let pwm = hardware.readPWM() else {
            stop()
            onFailure?("The keyboard backlight PWM could not be read")
            return
        }
        stats.lastPWM = pwm
        // Crossing time is somewhere within the last poll interval.
        let crossingTime = now - tuning.approachPollInterval / 2

        if pwm != approachLastPWM {
            if abs(pwm - approachLastPWM) == 1, let previous = approachLastCrossing, crossingTime > previous {
                approachMeasuredRate = 1 / (crossingTime - previous)
            }
            approachLastCrossing = crossingTime
            approachLastPWM = pwm
        }

        let synced = fade.direction == .down ? pwm <= syncThreshold : pwm >= syncThreshold
        if synced {
            // Down: we just entered bucket `pwm` through its upper edge. Up: through its lower edge.
            let edge = fade.direction == .down ? Double(pwm + 1) : Double(pwm)
            refineApproachDuration(using: fade)
            let rate = approachMeasuredRate ?? fade.rate
            let travelled = rate * (now - crossingTime)
            let position = fade.direction == .down ? edge - travelled : edge + travelled
            // Carry on in the same direction at hold speed: the quick approach fade overshoots too
            // easily for the first leg to be timed from it.
            command(fade.direction, speed: tuning.holdFadeSpeed, from: position, at: now)
            onTrace?(String(format: "sync pwm=%d %@ approach rate=%.2f/s", pwm, fade.direction == .down ? "down" : "up", rate))
            phase = .holding
            planNextReversal()
            scheduleWatchdog()
            return
        }

        if now - approachStart > tuning.approachTimeout {
            stop()
            onFailure?("The backlight did not reach the requested level")
            return
        }
        pendingTimer = clock.after(tuning.approachPollInterval) { [weak self] in self?.pollApproach() }
    }

    private func refineApproachDuration(using fade: Fade) {
        guard let rate = approachMeasuredRate, rate > 0 else { return }
        let estimate = abs(fade.goalX - fade.startX) / rate
        guard estimate.isFinite, estimate > 0.05, estimate < 30 else { return }
        tuning.approachDuration = tuning.approachDuration * 0.5 + estimate * 0.5
        onTuningChange?(tuning)
    }

    // MARK: - Hold

    private var bucketCentre: Double { Double(target ?? 0) + 0.5 }

    private func planNextReversal() {
        guard phase == .holding, let fade else { return }
        let now = clock.now
        let position = fade.position(at: now)
        let turn = fade.direction == .down ? bucketCentre - tuning.amplitude : bucketCentre + tuning.amplitude
        let remaining = fade.direction == .down ? position - turn : turn - position
        if remaining <= 0 {
            // Only happens straight after a sync that landed past the turn point; the PWM is on a
            // bucket edge then, so a verification read would be meaningless.
            reverse(at: now, position: position, verify: false)
            return
        }
        pendingTimer = clock.after(remaining / fade.rate) { [weak self] in
            guard let self, let fade = self.fade else { return }
            let time = self.clock.now
            self.reverse(at: time, position: fade.position(at: time))
        }
    }

    private func reverse(at time: TimeInterval, position: Double, verify: Bool = true) {
        guard phase == .holding, let fade, let target else { return }
        if verify, let pwm = hardware.readPWM() {
            stats.lastPWM = pwm
            if pwm != target {
                handleDrift(observed: pwm, during: fade)
                return
            }
        }
        stats.reversals += 1
        let next: Direction = fade.direction == .down ? .up : .down
        command(next, speed: tuning.holdFadeSpeed, from: position, at: time)
        planNextReversal()
    }

    private func scheduleWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = clock.after(tuning.watchdogInterval) { [weak self] in self?.watchdog() }
    }

    private func watchdog() {
        guard phase == .holding, let target, let fade else { return }
        guard let pwm = hardware.readPWM() else { return scheduleWatchdog() }
        stats.lastPWM = pwm
        stats.watchdogSamples += 1
        if pwm == target {
            stats.watchdogHits += 1
            scheduleWatchdog()
        } else {
            handleDrift(observed: pwm, during: fade)
        }
    }

    private func handleDrift(observed pwm: Int, during fade: Fade) {
        guard let target else { return }
        stats.resyncs += 1
        onTrace?(String(format: "drift pwm=%d while %@ at speed %d, model x=%.2f", pwm, fade.direction == .down ? "down" : "up", fade.fadeSpeed, fade.position(at: clock.now)))
        if fade.fadeSpeed == tuning.holdFadeSpeed {
            // Moving down but still too high, or moving up and already too high → the slow fade is
            // slower than modelled when the error opposes the motion, faster when it follows it.
            let tooHigh = pwm > target
            let errorFollowsMotion = (fade.direction == .up) == tooHigh
            let factor = errorFollowsMotion ? 1 - tuning.adaptationStep : 1 + tuning.adaptationStep
            tuning.holdDuration = min(max(tuning.holdDuration * factor, 5), 400)
            onTuningChange?(tuning)
        }
        let savedStats = stats
        startApproach()
        stats = savedStats
        stats.lastPWM = pwm
    }
}
