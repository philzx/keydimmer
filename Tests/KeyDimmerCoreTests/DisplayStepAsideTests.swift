import Foundation
import Testing
@testable import KeyDimmerCore

/// The display respects macOS the way the keyboard does: automatic brightness is paused while on a
/// shade, and a brightness change KeyDimmer didn't make takes over from a shade.
struct DisplayStepAsideTests {
    private static let floor = Level.systemBrightness(step: 1)

    @Test func aForeignChangeOnAShadeRemovesTheShadeAndLandsOnTheNearestSystemStep() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)
        rig.run(for: 1)

        rig.display.externalChange(to: 0.3)
        rig.run(for: 1)

        #expect(controller.level(of: .display) == .system(step: 5))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == 0.3)
    }

    @Test func ourOwnBrightnessEchoesNeverTakeOverFromAShade() {
        let rig = Rig()
        let controller = rig.launch()
        let shade = Ladder.display().shade(2)!

        // The echo of the system step arrives after we've already moved on to a shade.
        controller.select(.system(step: 8), on: .display)
        controller.select(shade, on: .display)
        controller.step(.display, by: 1)
        controller.step(.display, by: -1)
        rig.run(for: 1)

        #expect(controller.level(of: .display) == shade)
        #expect(rig.display.brightness() == Self.floor)
        #expect(rig.display.gammaFactor < 1)
    }

    @Test func aForeignChangeOnASystemStepJustUpdatesTheShownLevel() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 4), on: .display)
        rig.run(for: 1)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        rig.display.externalChange(to: 0.75)
        rig.run(for: 1)

        #expect(controller.level(of: .display) == .system(step: 12))
        #expect(rig.display.brightness() == 0.75)
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)
    }

    @Test func aStaleEchoOnASystemStepDoesNotMoveTheSlider() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(.system(step: 3), on: .display)
        controller.select(.system(step: 9), on: .display)
        rig.run(for: 1)

        #expect(controller.level(of: .display) == .system(step: 9))
    }

    // MARK: - Automatic brightness

    @Test(arguments: [true, false])
    func automaticBrightnessIsPausedOnAShadeAndHandedBackExactlyAsFound(autoBrightness: Bool) {
        let rig = Rig()
        rig.display.isAutoBrightnessEnabled = autoBrightness
        let controller = rig.launch()

        controller.select(Ladder.display().shade(2)!, on: .display)
        controller.step(.display, by: 1)
        #expect(rig.display.isAutoBrightnessEnabled == false)

        controller.select(.system(step: 6), on: .display)
        #expect(rig.display.isAutoBrightnessEnabled == autoBrightness)
    }

    @Test func aForeignChangeOnAShadeHandsAutomaticBrightnessBack() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(5)!, on: .display)
        rig.run(for: 1)

        rig.display.externalChange(to: 0.5)
        rig.run(for: 1)

        #expect(rig.display.isAutoBrightnessEnabled)
    }

    @Test func quittingOnAShadeHandsAutomaticBrightnessBack() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(1)!, on: .display)

        controller.willQuit()

        #expect(rig.display.isAutoBrightnessEnabled)
    }

    @Test func automaticBrightnessIsHandedBackOnTheLaunchAfterACrashThatLeftShades() {
        let rig = Rig()
        let crashed = rig.launch()
        crashed.select(Ladder.display().shade(4)!, on: .display)
        // The process died without quitting; macOS put the picture back, and the user moved the
        // display to a step before relaunching.
        rig.display.restoreGamma()
        rig.store.set(Level.system(step: 7).storageName, forKey: "displayLevel")

        _ = rig.launch()

        #expect(rig.display.isAutoBrightnessEnabled)
    }

    @Test func relaunchingOnAShadeKeepsAutomaticBrightnessPausedAndStillRemembersIt() {
        let rig = Rig()
        rig.launch().select(Ladder.display().shade(4)!, on: .display)
        rig.display.restoreGamma()

        let next = rig.launch()
        #expect(rig.display.isAutoBrightnessEnabled == false)

        next.select(.system(step: 3), on: .display)
        #expect(rig.display.isAutoBrightnessEnabled)
    }

    @Test func theKeyboardsAutomaticBrightnessIsLeftToTheKeyboard() {
        let rig = Rig()
        let controller = rig.launch()

        controller.select(Ladder.display().shade(4)!, on: .display)
        controller.select(.system(step: 3), on: .display)

        #expect(rig.backlight.isAutoBrightnessEnabled)
    }
}
