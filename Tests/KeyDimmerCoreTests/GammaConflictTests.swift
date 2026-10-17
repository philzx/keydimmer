import Foundation
import Testing
@testable import KeyDimmerCore

/// Shades stand down while another gamma app runs: two apps writing gamma tables would fight and flicker.
struct GammaConflictTests {
    private static let floor = Level.systemBrightness(step: 1)

    @Test func aGammaAppLaunchingWhileOnAShadeRemovesItAndLeavesTheDisplayAtItsFloor() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)

        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Tint", name: "Tint")

        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == Self.floor)
        #expect(controller.shadesUnavailableReason == "Shades are off while Tint is running")
    }

    @Test func aGammaAppLaunchingWhileOnASystemStepLeavesItAloneAndShadesCannotBeSelected() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 9), on: .display)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Dusk", name: "Dusk")
        #expect(controller.level(of: .display) == .system(step: 9))
        #expect(controller.shadesUnavailableReason == "Shades are off while Dusk is running")

        controller.select(Ladder.display().shade(5)!, on: .display)
        #expect(controller.level(of: .display) == .system(step: 9))

        controller.select(.system(step: 1), on: .display)
        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.gammaCommands == 0)
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands + 1)
    }

    @Test(arguments: [true, false])
    func aGammaAppRemovingAShadeHandsAutomaticBrightnessBackAsFound(autoBrightness: Bool) {
        let rig = Rig()
        rig.display.isAutoBrightnessEnabled = autoBrightness
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)
        #expect(rig.display.isAutoBrightnessEnabled == false)

        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Tint", name: "Tint")

        #expect(rig.display.isAutoBrightnessEnabled == autoBrightness)
        // A display shortcut stepping down from the floor can't reach a shade and pause it again.
        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.isAutoBrightnessEnabled == autoBrightness)
    }

    @Test func aSavedShadeStandingDownAtLaunchHandsAutomaticBrightnessBack() {
        let rig = Rig()
        rig.display.isAutoBrightnessEnabled = true
        rig.launch().select(Ladder.display().shade(4)!, on: .display)
        rig.display.restoreGamma() // The process ended on a shade; automatic brightness is still paused.
        #expect(rig.display.isAutoBrightnessEnabled == false)

        let next = LightController(
            keyboard: rig.backlight, display: rig.display, clock: rig.clock, store: rig.store,
            secondsSinceLastInput: { 0 }, hardwareModel: Rig.model, osBuild: Rig.build
        )
        next.otherGammaAppLaunched(bundleIdentifier: "com.example.Gloom", name: "Gloom")
        next.start()

        #expect(next.level(of: .display) == .system(step: 1))
        #expect(rig.display.isAutoBrightnessEnabled == true)
    }

    @Test func whenTheGammaAppQuitsShadesAreAvailableAgainButTheDisplayStaysWhereItIs() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)
        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Tint", name: "Tint")
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.otherGammaAppQuit(bundleIdentifier: "com.example.Tint")

        #expect(controller.shadesUnavailableReason == nil)
        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)
        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == Ladder.display().shade(8))
    }

    @Test func shadesStayUnavailableUntilEveryGammaAppHasQuit() {
        let rig = Rig()
        let controller = rig.launch()
        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Dusk", name: "Dusk")
        controller.otherGammaAppLaunched(bundleIdentifier: "com.example.Tint", name: "Tint")

        controller.otherGammaAppQuit(bundleIdentifier: "com.example.Dusk")
        #expect(controller.shadesUnavailableReason == "Shades are off while Tint is running")

        controller.otherGammaAppQuit(bundleIdentifier: "com.example.Tint")
        #expect(controller.shadesUnavailableReason == nil)
    }

    @Test func aSavedShadeIsNotReappliedWhileAGammaAppIsAlreadyRunningAtLaunch() {
        let rig = Rig()
        rig.launch().select(Ladder.display().shade(4)!, on: .display)
        rig.display.restoreGamma() // The process ended; macOS put the picture back.
        let gammaCommands = rig.display.gammaCommands

        let next = LightController(
            keyboard: rig.backlight, display: rig.display, clock: rig.clock, store: rig.store,
            secondsSinceLastInput: { 0 }, hardwareModel: Rig.model, osBuild: Rig.build
        )
        // The app layer reports what is already running before starting the controller.
        next.otherGammaAppLaunched(bundleIdentifier: "com.example.Gloom", name: "Gloom")
        next.start()

        #expect(next.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaCommands == gammaCommands)
        #expect(rig.display.brightness() == Self.floor)
        #expect(next.shadesUnavailableReason == "Shades are off while Gloom is running")
    }
}

/// The app layer matches running apps against the list by bundle identifier digest.
struct GammaAppsTests {
    private let apps = GammaApps(identifiers: ["com.example.Tint", "com.example.Dusk"], versionedPrefixes: ["com.example.Gloom."])

    @Test func listedIdentifiersMatchExactly() {
        #expect(apps.contains(bundleIdentifier: "com.example.Tint"))
        #expect(apps.contains(bundleIdentifier: "com.example.Dusk"))
        #expect(!apps.contains(bundleIdentifier: "com.example.TintHelper"))
        #expect(!apps.contains(bundleIdentifier: "com.apple.Safari"))
    }

    @Test func versionedIdentifiersMatchAnyMajorVersion() {
        #expect(apps.contains(bundleIdentifier: "com.example.Gloom.2"))
        #expect(apps.contains(bundleIdentifier: "com.example.Gloom.16"))
        #expect(!apps.contains(bundleIdentifier: "com.example.Gloom"))
        #expect(!apps.contains(bundleIdentifier: "com.example.Gloom."))
        #expect(!apps.contains(bundleIdentifier: "com.example.Gloom.beta"))
    }

    @Test func theKnownListIsStoredAsDigests() {
        #expect(GammaApps.digest("com.example.Tint").count == 64)
        #expect(!GammaApps.known.contains(bundleIdentifier: "com.apple.Safari"))
    }
}
