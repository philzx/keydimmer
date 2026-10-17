import Foundation
import Testing
@testable import KeyDimmerCore

/// Settings kept in memory, so each test starts from a clean install and a second controller on
/// the same store behaves like the next launch.
final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// A Mac under test: the simulated keyboard and built-in display, the fake clock and the user's
/// input, with the controller wired the way the app wires it (brightness notifications arrive
/// asynchronously).
final class Rig {
    static let model = "Mac15,13"
    static let build = "25A354"

    let clock = FakeClock()
    let backlight: SimulatedBacklight
    let display = SimulatedDisplay()
    let store = MemoryStore()
    var secondsIdle: TimeInterval = 0

    init(floorPWM: Double = 54, cachedFloor: Int? = 54) {
        backlight = SimulatedBacklight(clock: clock, floorPWM: floorPWM)
        if let cachedFloor { cacheFloor(cachedFloor, build: Self.build) }
    }

    func cacheFloor(_ floor: Int, build: String) {
        store.set(floor, forKey: FloorProbe.cacheKey(model: Self.model))
        store.set(build, forKey: FloorProbe.cacheKey(model: Self.model) + ".osBuild")
    }

    /// Launches KeyDimmer.
    func launch() -> LightController {
        let controller = LightController(
            hardware: backlight, display: display, clock: clock, store: store,
            secondsSinceLastInput: { [unowned self] in self.secondsIdle },
            hardwareModel: Self.model, osBuild: Self.build
        )
        backlight.observeBrightness { [clock, weak controller] value in
            _ = clock.after(0) { controller?.brightnessChanged(to: value) }
        }
        controller.start()
        return controller
    }

    func run(for seconds: TimeInterval) { clock.run(until: clock.now + seconds) }
}

struct LightControllerTests {
    // MARK: - Select and step

    @Test func selectingASystemStepHandsItToMacOS() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(.system(step: 8))
        rig.run(for: 1)

        #expect(controller.level == .system(step: 8))
        #expect(rig.backlight.brightness() == 0.5)
    }

    @Test func steppingMovesOneLevelAndDoesNothingAtEitherEnd() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(.system(step: 3))
        controller.step(by: 1)
        #expect(controller.level == .system(step: 4))

        controller.select(.system(step: 16))
        rig.run(for: 1)
        let commands = rig.backlight.commands
        controller.step(by: 1)
        #expect(controller.level == .system(step: 16))
        #expect(rig.backlight.commands == commands)

        controller.select(.off)
        rig.run(for: 1)
        let offCommands = rig.backlight.commands
        controller.step(by: -1)
        #expect(controller.level == .off)
        #expect(rig.backlight.commands == offCommands)
    }

    // MARK: - Embers and macOS's own features

    private func emberPWM(_ controller: LightController, _ index: Int) -> Int {
        guard case let .ember(_, pwm)? = controller.ladder.ember(index) else { return -1 }
        return pwm
    }

    @Test func anEmberIsHeldBelowTheFloorWithAutoBrightnessAndIdleDimmingTakenOver() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(index: 3)
        rig.run(for: 30)

        #expect(controller.level == controller.ladder.ember(3))
        #expect(rig.backlight.pwm == emberPWM(controller, 3))
        #expect(rig.backlight.pwm < 54)
        #expect(rig.backlight.isAutoBrightnessEnabled == false)
        #expect(rig.backlight.idleSuspended)
    }

    @Test(arguments: [true, false])
    func leavingAnEmberHandsMacOSFeaturesBackExactlyAsFound(autoBrightness: Bool) {
        let rig = Rig()
        rig.backlight.isAutoBrightnessEnabled = autoBrightness
        let controller = rig.launch()

        controller.select(index: 2)
        rig.run(for: 5)
        controller.step(by: 1)
        rig.run(for: 5)
        controller.select(.system(step: 5))
        rig.run(for: 1)

        #expect(rig.backlight.isAutoBrightnessEnabled == autoBrightness)
        #expect(rig.backlight.idleSuspended == false)
    }

    @Test func automaticBrightnessIsRestoredAfterACrashOnAnEmber() {
        let rig = Rig()
        let crashed = rig.launch()
        crashed.select(index: 4)
        rig.run(for: 5)
        #expect(rig.backlight.isAutoBrightnessEnabled == false)

        // The crash left the ember saved; then macOS's own step was chosen before relaunching.
        rig.store.set("system:6", forKey: "level")
        _ = rig.launch()

        #expect(rig.backlight.isAutoBrightnessEnabled)
        #expect(rig.backlight.idleSuspended == false)
    }

    @Test func relaunchingOnASavedEmberKeepsMacOSFeaturesTakenOverAndRestoresThemLater() {
        let rig = Rig()
        let first = rig.launch()
        first.select(index: 4)
        rig.run(for: 5)

        let second = rig.launch()
        rig.run(for: 10)
        #expect(second.level == second.ladder.ember(4))
        #expect(rig.backlight.isAutoBrightnessEnabled == false)

        second.select(.system(step: 2))
        #expect(rig.backlight.isAutoBrightnessEnabled)
    }

    // MARK: - Step-aside

    @Test func anEmberStepsAsideWhenSomeoneElseChangesTheBrightness() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 30)

        rig.backlight.externalFade(to: 0.25, fadeSpeed: 350)
        rig.run(for: 1)

        #expect(controller.level == .system(step: 4))
        #expect(controller.pause == nil)
        #expect(rig.backlight.isAutoBrightnessEnabled)
        #expect(rig.backlight.idleSuspended == false)
        // Nothing keeps commanding fades once we have stepped aside.
        let commands = rig.backlight.commands
        rig.run(for: 60)
        #expect(rig.backlight.commands == commands)
    }

    @Test func theHoldEnginesOwnGoalsAreNotMistakenForSomeoneElse() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 5)
        rig.run(for: 300)

        #expect(controller.level == controller.ladder.ember(5))
        #expect(rig.backlight.pwm == emberPWM(controller, 5))
    }

    @Test func aSystemStepFollowsBrightnessChangesMadeElsewhere() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 4))
        rig.run(for: 1)

        rig.backlight.externalFade(to: 0.75, fadeSpeed: 350)
        rig.run(for: 1)

        #expect(controller.level == .system(step: 12))
    }

    // MARK: - Pauses

    @Test func anEmberPausesWhileTheLidIsClosed() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 10)

        rig.backlight.lidClosed = true
        rig.run(for: 2)
        #expect(controller.pause == .lidClosed)
        // A goal of 0 is ignored while the hold's slow fade down is in flight, so the light can
        // take until the end of that fade to go dark.
        rig.run(for: HoldEngine.Tuning().holdDuration)
        #expect(rig.backlight.pwm == 0)

        rig.backlight.lidClosed = false
        rig.run(for: 15)
        #expect(controller.pause == nil)
        #expect(rig.backlight.pwm == emberPWM(controller, 3))
    }

    @Test func anEmberTurnsOffAfterMacOSsInactivityTimeoutAndReturnsOnInput() {
        let rig = Rig()
        rig.backlight.idleDimSeconds = 30
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 10)

        rig.secondsIdle = 31
        rig.run(for: 5)
        #expect(controller.pause == .inactive)
        rig.run(for: HoldEngine.Tuning().holdDuration)
        #expect(controller.pause == .inactive)
        #expect(rig.backlight.pwm == 0)

        rig.secondsIdle = 0
        rig.run(for: 15)
        #expect(controller.pause == nil)
        #expect(rig.backlight.pwm == emberPWM(controller, 3))
    }

    @Test func anEmberIgnoresInactivityWhenNotFollowingIt() {
        let rig = Rig()
        rig.backlight.idleDimSeconds = 30
        let controller = rig.launch()
        controller.followsInactivity = false
        controller.select(index: 3)
        rig.run(for: 10)

        rig.secondsIdle = 31
        rig.run(for: 5)

        #expect(controller.pause == nil)
        #expect(rig.backlight.pwm == emberPWM(controller, 3))
        #expect(rig.launch().followsInactivity == false)
    }

    @Test func anEmberPausesForSleepAndResumesOneSecondAfterWaking() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 10)

        controller.willSleep()
        rig.run(for: HoldEngine.Tuning().holdDuration)
        #expect(controller.pause == .sleeping)
        #expect(rig.backlight.pwm == 0)

        controller.didWake()
        rig.run(for: 0.9)
        #expect(controller.pause == .sleeping)
        rig.run(for: 0.2)
        #expect(controller.pause == nil)
        rig.run(for: 15)
        #expect(rig.backlight.pwm == emberPWM(controller, 3))
    }

    @Test func sleepLeavesSystemStepsToMacOS() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 4))
        rig.run(for: 1)
        let commands = rig.backlight.commands

        controller.willSleep()
        controller.didWake()
        rig.run(for: 5)

        #expect(controller.pause == nil)
        #expect(rig.backlight.commands == commands)
    }

    // MARK: - Floor calibration

    @Test func theFirstEmberMeasuresTheFloorCachesItAndHoldsOnTheNewLadder() {
        let rig = Rig(floorPWM: 40, cachedFloor: nil)
        let controller = rig.launch()
        #expect(controller.floorIsMeasured == false)

        controller.select(index: 6)
        #expect(controller.isCalibrating)
        rig.run(for: 30)

        #expect(controller.isCalibrating == false)
        #expect(controller.floorIsMeasured)
        #expect(controller.ladder == Ladder(floorPWM: 40))
        #expect(controller.level == Ladder(floorPWM: 40).ember(6))
        #expect(rig.backlight.pwm == emberPWM(controller, 6))
        #expect(rig.launch().ladder == Ladder(floorPWM: 40))
    }

    @Test func aFloorMeasuredOnAnotherMacOSBuildIsMeasuredAgain() {
        let rig = Rig(floorPWM: 40, cachedFloor: nil)
        rig.cacheFloor(54, build: "24G84")
        let controller = rig.launch()
        #expect(controller.floorIsMeasured == false)

        controller.select(index: 2)
        rig.run(for: 30)

        #expect(controller.ladder == Ladder(floorPWM: 40))
    }

    @Test func recalibratingReselectsTheLevelOnTheRebuiltLadder() {
        let rig = Rig(floorPWM: 40, cachedFloor: 54)
        let controller = rig.launch()
        controller.select(index: 8)
        rig.run(for: 10)

        controller.recalibrate()
        #expect(controller.isCalibrating)
        rig.run(for: 30)

        #expect(controller.calibrationFailed == false)
        #expect(controller.ladder == Ladder(floorPWM: 40))
        #expect(controller.level == Ladder(floorPWM: 40).ember(8))
        #expect(rig.backlight.pwm == emberPWM(controller, 8))
    }

    @Test func selectingDuringCalibrationIsIgnored() {
        let rig = Rig(cachedFloor: nil)
        let controller = rig.launch()
        controller.select(index: 2)

        controller.select(.system(step: 9))
        rig.run(for: 30)

        #expect(controller.level == controller.ladder.ember(2))
    }

    // MARK: - Quit and persistence

    @Test func quittingOnAnEmberLeavesTheKeyboardAtTheDimmestHoldableLevel() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 30)

        controller.willQuit()
        rig.run(for: 5)

        #expect(rig.backlight.brightness() == HoldEngine.Tuning().floorGoal)
        #expect(rig.backlight.pwm == 54)
        #expect(rig.backlight.isAutoBrightnessEnabled)
        #expect(rig.backlight.idleSuspended == false)
    }

    @Test func quittingOnASystemStepLeavesIt() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 7))
        rig.run(for: 1)

        controller.willQuit()

        #expect(rig.backlight.brightness() == Level.systemBrightness(step: 7))
    }

    @Test func anEmberIsRememberedAcrossLaunches() {
        let rig = Rig()
        rig.launch().select(index: 4)
        rig.run(for: 10)

        let next = rig.launch()
        rig.run(for: 10)

        #expect(next.level == next.ladder.ember(4))
        #expect(rig.backlight.pwm == emberPWM(next, 4))
    }

    @Test func aSystemStepIsReadBackFromMacOSOnLaunch() {
        let rig = Rig()
        rig.launch().select(.system(step: 3))
        rig.run(for: 1)
        rig.backlight.externalFade(to: 0.625, fadeSpeed: 0)

        let next = rig.launch()

        #expect(next.level == .system(step: 10))
    }
}
