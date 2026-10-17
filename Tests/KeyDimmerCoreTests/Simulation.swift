import Foundation
@testable import KeyDimmerCore

/// Deterministic clock that runs scheduled work in time order.
final class FakeClock: EngineClock {
    private final class Item: Cancellable {
        let time: TimeInterval
        let sequence: Int
        let work: () -> Void
        var cancelled = false

        init(time: TimeInterval, sequence: Int, work: @escaping () -> Void) {
            self.time = time
            self.sequence = sequence
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var sequence = 0

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
        sequence += 1
        let item = Item(time: now + max(delay, 0), sequence: sequence, work: work)
        items.append(item)
        return item
    }

    /// Runs every item due up to `end`, calling `observe` with the time before each one.
    func run(until end: TimeInterval, observe: (TimeInterval) -> Void = { _ in }) {
        while true {
            items.removeAll { $0.cancelled }
            guard let next = items.min(by: { ($0.time, $0.sequence) < ($1.time, $1.sequence) }), next.time <= end else { break }
            items.removeAll { $0 === next }
            observe(next.time)
            now = next.time
            next.work()
        }
        now = end
    }
}

/// Keyboard backlight that behaves like the measured hardware: each command starts a linear fade
/// from the current output to its goal over a duration fixed by the fade speed; a command whose
/// goal matches the fade in flight is ignored; non-zero goals land on the floor or above it.
final class SimulatedBacklight: BacklightHardware {
    let clock: FakeClock
    let floorPWM: Double
    let slope: Double
    var durations: [Int32: TimeInterval]
    var latency: TimeInterval
    private(set) var commands = 0

    private var startX: Double
    private var goalX: Double
    private var goalValue: Float
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var brightnessHandlers: [(Float) -> Void] = []

    let totalPeriod = 960
    var isAutoBrightnessEnabled = true
    var idleSuspended = false
    var lidClosed = false
    /// The user's "turn keyboard backlight off after inactivity" setting; 0 means never.
    var idleDimSeconds: TimeInterval = 0

    init(clock: FakeClock, floorPWM: Double = 54, slope: Double = 282, startPWM: Double = 70,
         durations: [Int32: TimeInterval] = [500_000: 41, 2_000: 2, 350: 0.36, 0: 0], latency: TimeInterval = 0) {
        self.clock = clock
        self.floorPWM = floorPWM
        self.slope = slope
        self.durations = durations
        self.latency = latency
        startX = startPWM
        goalX = startPWM
        goalValue = Float((startPWM - floorPWM) / slope)
    }

    /// Starts a fade as if another process had commanded it.
    func externalFade(to value: Float, fadeSpeed: Int32) { setBrightness(value, fadeSpeed: fadeSpeed, commit: false) }

    func x(at time: TimeInterval) -> Double {
        guard duration > 0 else { return goalX }
        let progress = min(max((time - startTime) / duration, 0), 1)
        return startX + (goalX - startX) * progress
    }

    var pwm: Int { Int(x(at: clock.now).rounded(.down)) }

    func readPWM() -> Int? { pwm }

    func brightness() -> Float { goalValue }

    func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool) {
        commands += 1
        let newGoal = value <= 0 ? 0 : floorPWM + slope * Double(value)
        if newGoal == goalX, x(at: clock.now) != goalX { return }
        let time = clock.now + latency
        startX = x(at: time)
        startTime = time
        goalX = newGoal
        goalValue = value
        duration = durations[fadeSpeed] ?? Double(fadeSpeed) / 1000
        brightnessHandlers.forEach { $0(value) }
    }

    func setAutoBrightness(_ enabled: Bool) { isAutoBrightnessEnabled = enabled }
    func setIdleDimmingSuspended(_ suspended: Bool) { idleSuspended = suspended }
    func idleDimTime() -> TimeInterval { idleDimSeconds }
    func isLidClosed() -> Bool { lidClosed }
    func observeBrightness(_ handler: @escaping (Float) -> Void) { brightnessHandlers.append(handler) }
}
