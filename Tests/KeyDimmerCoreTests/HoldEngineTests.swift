import Foundation
import Testing
@testable import KeyDimmerCore

struct HoldEngineTests {
    /// Samples the simulated PWM every 50 ms after `settle` seconds and returns the on-target fraction.
    private func onTargetFraction(
        engine: HoldEngine, backlight: SimulatedBacklight, clock: FakeClock,
        target: Int, settle: TimeInterval = 5, duration: TimeInterval
    ) -> Double {
        let start = clock.now
        clock.run(until: start + settle)
        var hits = 0
        var samples = 0
        var t = clock.now
        let end = start + settle + duration
        while t < end {
            t += 0.05
            clock.run(until: t)
            samples += 1
            if backlight.pwm == target { hits += 1 }
        }
        return Double(hits) / Double(samples)
    }

    @Test(arguments: [1, 3, 7, 20, 43])
    func holdsTargetWithoutVisibleSteps(target: Int) {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: target)

        let fraction = onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: target, duration: 1200)

        #expect(engine.phase == .holding)
        #expect(fraction > 0.999, "on target \(fraction * 100)% of the time")
        #expect(engine.stats.resyncs <= 1)
    }

    @Test(arguments: [25.0, 33.0, 52.0, 70.0])
    func staysOnTargetWhenTheSlowFadeDurationIsMisjudged(actual: TimeInterval) {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, durations: [500_000: actual, 2_000: 2, 350: 0.36])
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: 5)

        let fraction = onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: 5, duration: 1800)

        #expect(fraction > 0.99, "on target \(fraction * 100)% of the time, \(engine.stats.resyncs) resyncs")
    }

    @Test func toleratesCommandLatency() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, latency: 0.003)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: 4)

        let fraction = onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: 4, duration: 1200)

        #expect(fraction > 0.99, "on target \(fraction * 100)% of the time")
    }

    @Test func movesBetweenEmbersAndFromOff() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, startPWM: 0)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)

        engine.hold(pwm: 12)
        #expect(onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: 12, duration: 120) > 0.99)

        engine.hold(pwm: 2)
        #expect(onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: 2, duration: 120) > 0.99)

        engine.hold(pwm: 30)
        #expect(onTargetFraction(engine: engine, backlight: backlight, clock: clock, target: 30, duration: 120) > 0.99)
    }

    @Test func usesFewCommandsWhileHolding() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: 6)
        clock.run(until: 10)
        let before = backlight.commands

        clock.run(until: 610)

        // Each cycle is one up and one down command and lasts ~3 s at target 6.
        #expect(backlight.commands - before < 600)
    }

    @Test func firstCommandTakesEffectWhenItsGoalIsAlreadyInFlight() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, startPWM: 2)
        backlight.externalFade(to: HoldEngine.Tuning().floorGoal, fadeSpeed: 500_000)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)

        engine.hold(pwm: 20)
        clock.run(until: 2)

        #expect(engine.phase == .holding)
        #expect(backlight.pwm == 20)
    }

    @Test func stopGoesIdle() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: 6)
        clock.run(until: 10)

        engine.stop()
        let commands = backlight.commands
        clock.run(until: 100)

        #expect(engine.phase == .idle)
        #expect(backlight.commands == commands)
    }

    @Test(arguments: [true, false], [0, 0.003])
    func fadeOutTurnsTheLightOffAtItsOwnSpeedWhicheverWayTheHoldIsFading(fadingDown: Bool, latency: TimeInterval) {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, latency: latency)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)
        engine.hold(pwm: 6)
        clock.run(until: 10)
        let goal: Float = fadingDown ? 0 : HoldEngine.Tuning().floorGoal
        while backlight.brightness() != goal { clock.run(until: clock.now + 0.001) }

        engine.fadeOut(fadeSpeed: 0)
        clock.run(until: clock.now + 0.1)

        #expect(engine.phase == .idle)
        #expect(backlight.pwm == 0)
        #expect(engine.lastCommandedGoal == 0)
    }

    @Test func clampsTargetsBelowTheFloor() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock)
        let engine = HoldEngine(hardware: backlight, clock: clock, floorPWM: 54)

        engine.hold(pwm: 200)
        #expect(engine.target == 53)
        engine.hold(pwm: 0)
        #expect(engine.target == 1)
    }
}

struct FloorProbeTests {
    @Test func measuresTheFloorEvenWhenAFadeToItIsInFlight() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, startPWM: 3)
        // A previous session left a slow fade towards the floor running.
        backlight.externalFade(to: HoldEngine.Tuning().floorGoal, fadeSpeed: 500_000)
        var measured: Int?

        FloorProbe.measure(hardware: backlight, clock: clock) { measured = $0 }
        clock.run(until: 1)

        #expect(measured == 54)
    }

    @Test func rejectsImplausibleFloors() {
        let clock = FakeClock()
        let backlight = SimulatedBacklight(clock: clock, floorPWM: 4, startPWM: 4)
        var measured: Int? = -1

        FloorProbe.measure(hardware: backlight, clock: clock) { measured = $0 }
        clock.run(until: 1)

        #expect(measured == nil)
    }
}

struct LadderTests {
    @Test func spreadsEmbersUpToMostOfTheFloor() {
        let targets = Ladder.emberTargets(floorPWM: 54, count: 12)

        #expect(targets.count == 12)
        #expect(targets.first == 1)
        #expect(targets.last == 43)
        #expect(zip(targets, targets.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func handlesTinyFloors() {
        let targets = Ladder.emberTargets(floorPWM: 6, count: 12)

        #expect(targets == [1, 2, 3, 4, 5])
    }

    @Test func ordersOffEmbersThenSystemSteps() {
        let ladder = Ladder(floorPWM: 54)

        #expect(ladder.count == 1 + 12 + 16)
        #expect(ladder.levels.first == .off)
        #expect(ladder.levels[1] == .ember(index: 1, pwm: 1))
        #expect(ladder.levels.last == .system(step: 16))
        #expect(ladder.nearestLevel(forBrightness: 0.5) == .system(step: 8))
        #expect(ladder.nearestLevel(forBrightness: 0.001) == .system(step: 1))
        #expect(ladder.nearestLevel(forBrightness: 0) == .off)
    }
}
