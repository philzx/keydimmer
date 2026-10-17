import Foundation
import Testing
@testable import KeyDimmerCore

struct DisplayLightTests {
    // MARK: - Ladder

    private func shadeFactors(_ ladder: Ladder) -> [Float] {
        ladder.levels.compactMap { if case let .shade(_, factor) = $0 { return factor } else { return nil } }
    }

    @Test func theDisplayLadderIsEightShadesThenSixteenSystemStepsWithNoOff() {
        let ladder = Ladder.display()

        #expect(ladder.count == 24)
        #expect(!ladder.levels.contains(.off))
        #expect(!ladder.levels.contains { $0.isEmber })
        #expect(ladder.levels.prefix(8).allSatisfy { $0.isShade })
        #expect(ladder.shade(1) == ladder.levels[0])
        #expect(ladder.shade(8) == ladder.levels[7])
        #expect(Array(ladder.levels.suffix(16)) == (1...16).map { Level.system(step: $0) })
    }

    @Test func shadesAreSpacedGeometricallyFromAReadableDarkestShadeUpToJustBelowTheFloor() {
        let factors = shadeFactors(Ladder.display())

        #expect(factors.count == 8)
        // The darkest shade keeps roughly 10-15% of the picture, so it stays readable.
        #expect(factors[0] >= 0.10 && factors[0] <= 0.15)
        // The brightest shade sits right below the dimmest system step: just under the full picture.
        #expect(factors[7] >= 0.85 && factors[7] < 0.95)
        // Every step between shades is the same change in darkness.
        let ratios = zip(factors.dropFirst(), factors).map { $0 / $1 }
        for ratio in ratios { #expect(abs(ratio - ratios[0]) < 0.0001) }
    }

    @Test func theDisplayFloorIsTheDimmestSystemStep() {
        let ladder = Ladder.display()

        #expect(ladder.nearestLevel(forBrightness: 0) == .system(step: 1))
        #expect(ladder.nearestLevel(forBrightness: 0.01) == .system(step: 1))
        #expect(ladder.nearestLevel(forBrightness: 0.5) == .system(step: 8))
    }

    // MARK: - Shades and system steps

    private static let floor = Level.systemBrightness(step: 1)

    private func factor(_ level: Level?) -> Float {
        if case let .shade(_, factor)? = level { return factor }
        return -1
    }

    @Test func selectingAShadePutsTheDisplayOnItsFloorAndDarkensThePicture() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(index: 2, on: .display)

        let shade3 = Ladder.display().shade(3)
        #expect(controller.level(of: .display) == shade3)
        #expect(rig.display.brightness() == Self.floor)
        #expect(rig.display.gammaFactor == factor(shade3))
        #expect(rig.display.gammaFactor < 1)
    }

    @Test func selectingASystemStepRestoresThePictureAndHandsBrightnessToMacOS() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 0, on: .display)

        controller.select(.system(step: 8), on: .display)

        #expect(controller.level(of: .display) == .system(step: 8))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == 0.5)
    }

    @Test func steppingUpFromTheBrightestShadeLandsOnTheFloorAndStopsAtEitherEnd() {
        let rig = Rig()
        let controller = rig.launch()
        let ladder = Ladder.display()

        controller.select(ladder.shade(8)!, on: .display)
        controller.step(.display, by: 1)
        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == Self.floor)

        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == ladder.shade(8))

        controller.select(ladder.shade(1)!, on: .display)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands
        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == ladder.shade(1))
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)

        controller.select(.system(step: 16), on: .display)
        controller.step(.display, by: 1)
        #expect(controller.level(of: .display) == .system(step: 16))
    }

    @Test func theDisplayHasNoOffAndNoEmbers() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 5), on: .display)

        controller.select(.off, on: .display)
        controller.select(.ember(index: 1, pwm: 1), on: .display)

        #expect(controller.level(of: .display) == .system(step: 5))
        #expect(rig.display.brightness() == Level.systemBrightness(step: 5))
    }

    @Test func theKeyboardIsUntouchedByTheDisplay() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 6))
        rig.run(for: 1)
        let commands = rig.backlight.commands

        controller.select(index: 3, on: .display)
        controller.step(.display, by: 10)
        rig.run(for: 5)

        #expect(controller.level == .system(step: 6))
        #expect(rig.backlight.commands == commands)
    }

    @Test func movingBetweenSystemStepsLeavesThePictureAlone() {
        // Another app's gamma, or ColorSync's, is none of our business until we shade.
        let rig = Rig()
        let controller = rig.launch()

        controller.select(.system(step: 4), on: .display)
        controller.step(.display, by: 1)

        #expect(rig.display.gammaCommands == 0)
        #expect(rig.display.brightness() == Level.systemBrightness(step: 5))
    }

    @Test func movingBetweenShadesKeepsTheBacklightStill() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 1, on: .display)
        let brightnessCommands = rig.display.brightnessCommands

        controller.step(.display, by: 1)
        controller.step(.display, by: 1)

        #expect(controller.level(of: .display) == Ladder.display().shade(4))
        #expect(rig.display.gammaFactor == factor(Ladder.display().shade(4)))
        #expect(rig.display.brightnessCommands == brightnessCommands)
    }

    // MARK: - Sleep, wake and lock

    @Test func sleepRemovesTheShadeAndWakingReappliesItOneSecondLater() {
        let rig = Rig()
        let controller = rig.launch()
        let shade3 = Ladder.display().shade(3)
        controller.select(shade3!, on: .display)

        controller.willSleep()
        #expect(rig.display.gammaFactor == 1)
        #expect(controller.level(of: .display) == shade3)

        controller.didWake()
        rig.run(for: 0.9)
        #expect(rig.display.gammaFactor == 1)
        rig.run(for: 0.2)
        #expect(rig.display.gammaFactor == factor(shade3))
        #expect(rig.display.brightness() == Self.floor)
    }

    @Test func wakingLeavesALevelTheUserChoseDuringTheGraceAlone() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 2, on: .display)
        controller.willSleep()
        controller.didWake()

        controller.select(.system(step: 6), on: .display)
        rig.run(for: 5)

        #expect(controller.level(of: .display) == .system(step: 6))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == Level.systemBrightness(step: 6))
    }

    /// macOS and the panel move the brightness around while the screens sleep and wake; like Lunar,
    /// the shade ignores that until the grace is over.
    @Test func brightnessChangesWhileAsleepOrDuringTheWakeGraceDoNotRemoveTheShade() {
        let rig = Rig()
        let controller = rig.launch()
        let shade3 = Ladder.display().shade(3)
        controller.select(shade3!, on: .display)

        controller.willSleep()
        rig.display.externalChange(to: 0)
        rig.run(for: 10)
        controller.didWake()
        rig.display.externalChange(to: 0.4)
        rig.run(for: 2)

        #expect(controller.level(of: .display) == shade3)
        #expect(rig.display.gammaFactor == factor(shade3))
        #expect(rig.display.brightness() == Self.floor)
        #expect(rig.display.isAutoBrightnessEnabled == false)
    }

    @Test func aBrightnessChangeAfterTheWakeGraceStillTakesOverFromTheShade() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)
        controller.willSleep()
        controller.didWake()
        rig.run(for: 2)

        rig.display.externalChange(to: 0.3)
        rig.run(for: 1)

        #expect(controller.level(of: .display) == .system(step: 5))
        #expect(rig.display.gammaFactor == 1)
    }

    @Test func wakingTwiceAndSleepingAgainBeforeTheGraceEndsLeavesThePictureUnshaded() {
        // Sleep, then display sleep, then their two wakes: macOS sends both.
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 2, on: .display)
        controller.willSleep()
        controller.willSleep()
        controller.didWake()
        controller.didWake()
        rig.run(for: 0.5)

        controller.willSleep()
        rig.run(for: 5)
        #expect(rig.display.gammaFactor == 1)

        controller.didWake()
        rig.run(for: 1.1)
        #expect(rig.display.gammaFactor == factor(Ladder.display().shade(3)))
    }

    @Test func sleepLeavesTheDisplaysSystemStepsToMacOS() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 4), on: .display)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.willSleep()
        controller.didWake()
        rig.run(for: 5)

        #expect(controller.level(of: .display) == .system(step: 4))
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)
    }

    // MARK: - Launch, quit and persistence

    @Test func launchingShowsTheSystemStepMacOSIsAt() {
        let rig = Rig()
        rig.display.externalChange(to: 0.75)

        let controller = rig.launch()

        #expect(controller.level(of: .display) == .system(step: 12))
        #expect(rig.display.brightnessCommands == 0)
        #expect(rig.display.gammaCommands == 0)
    }

    @Test func aShadeIsRememberedAcrossLaunches() {
        let rig = Rig()
        rig.launch().select(Ladder.display().shade(4)!, on: .display)
        // The process ended; macOS put the picture back.
        rig.display.restoreGamma()

        let next = rig.launch()

        #expect(next.level(of: .display) == Ladder.display().shade(4))
        #expect(rig.display.gammaFactor == factor(Ladder.display().shade(4)))
        #expect(rig.display.brightness() == Self.floor)
    }

    @Test func aSystemStepIsReadBackFromMacOSOnLaunch() {
        let rig = Rig()
        rig.launch().select(.system(step: 3), on: .display)
        rig.display.externalChange(to: 0.625)

        let next = rig.launch()

        #expect(next.level(of: .display) == .system(step: 10))
    }

    @Test func quittingOnAShadeRestoresThePictureAndLeavesTheDisplayAtItsFloor() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 2, on: .display)

        controller.willQuit()

        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == Self.floor)
    }

    @Test func quittingOnASystemStepLeavesTheDisplayAlone() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 9), on: .display)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.willQuit()

        #expect(rig.display.brightness() == Level.systemBrightness(step: 9))
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)
    }

    @Test func aMacWithoutABuiltInDisplayHasNoDisplayLight() {
        let rig = Rig()
        let controller = LightController(
            keyboard: rig.backlight, clock: rig.clock, store: rig.store, secondsSinceLastInput: { 0 },
            hardwareModel: Rig.model, osBuild: Rig.build
        )
        controller.start()

        controller.select(index: 0, on: .display)
        controller.step(.display, by: 1)
        controller.willQuit()

        #expect(controller.ladder(of: .display) == nil)
        #expect(controller.level(of: .display) == nil)
    }
}
