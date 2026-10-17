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

        controller.otherGammaAppLaunched(bundleIdentifier: "org.herf.Flux")

        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaFactor == 1)
        #expect(rig.display.brightness() == Self.floor)
        #expect(controller.shadesUnavailableReason == "f.lux is running")
    }

    @Test func aGammaAppLaunchingWhileOnASystemStepLeavesItAloneAndShadesCannotBeSelected() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 9), on: .display)
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.otherGammaAppLaunched(bundleIdentifier: "pro.betterdisplay.BetterDisplay")
        #expect(controller.level(of: .display) == .system(step: 9))
        #expect(controller.shadesUnavailableReason == "BetterDisplay is running")

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

        controller.otherGammaAppLaunched(bundleIdentifier: "org.herf.Flux")

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
        next.otherGammaAppLaunched(bundleIdentifier: "fyi.lunar.Lunar")
        next.start()

        #expect(next.level(of: .display) == .system(step: 1))
        #expect(rig.display.isAutoBrightnessEnabled == true)
    }

    @Test func whenTheGammaAppQuitsShadesAreAvailableAgainButTheDisplayStaysWhereItIs() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(Ladder.display().shade(3)!, on: .display)
        controller.otherGammaAppLaunched(bundleIdentifier: "org.herf.Flux")
        let commands = rig.display.brightnessCommands + rig.display.gammaCommands

        controller.otherGammaAppQuit(bundleIdentifier: "org.herf.Flux")

        #expect(controller.shadesUnavailableReason == nil)
        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == commands)
        controller.step(.display, by: -1)
        #expect(controller.level(of: .display) == Ladder.display().shade(8))
    }

    @Test func shadesStayUnavailableUntilEveryGammaAppHasQuit() {
        let rig = Rig()
        let controller = rig.launch()
        controller.otherGammaAppLaunched(bundleIdentifier: "me.guillaumeb.MonitorControl")
        controller.otherGammaAppLaunched(bundleIdentifier: "ca.michelf.GammaControl.6")

        controller.otherGammaAppQuit(bundleIdentifier: "me.guillaumeb.MonitorControl")
        #expect(controller.shadesUnavailableReason == "Gamma Control is running")

        controller.otherGammaAppQuit(bundleIdentifier: "ca.michelf.GammaControl.6")
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
        next.otherGammaAppLaunched(bundleIdentifier: "fyi.lunar.Lunar")
        next.start()

        #expect(next.level(of: .display) == .system(step: 1))
        #expect(rig.display.gammaCommands == gammaCommands)
        #expect(rig.display.brightness() == Self.floor)
        #expect(next.shadesUnavailableReason == "Lunar is running")
    }

    @Test func onlyKnownGammaAppsConflict() {
        let rig = Rig()
        let controller = rig.launch()
        for id in [
            "com.apple.Safari", "me.guillaumeb.MonitorControlHelper", "app.monitorcontrol.MonitorControlHelper",
            "ca.michelf.GammaControl", "ca.michelf.GammaControl.", "ca.michelf.BlackLight.beta",
        ] {
            controller.otherGammaAppLaunched(bundleIdentifier: id)
        }
        #expect(controller.shadesUnavailableReason == nil)

        for (id, name) in [
            ("fyi.lunar.LunarLite", "Lunar Lite"), ("app.monitorcontrol.MonitorControl", "MonitorControl"),
            ("app.monitorcontrol.MonitorControlLite", "MonitorControl Lite"), ("ca.michelf.BlackLight.2", "BlackLight"),
            ("com.lowtechguys.GammaDimmer", "Gamma Dimmer"),
        ] {
            controller.otherGammaAppLaunched(bundleIdentifier: id)
            #expect(controller.shadesUnavailableReason == "\(name) is running")
            controller.otherGammaAppQuit(bundleIdentifier: id)
        }
    }
}
