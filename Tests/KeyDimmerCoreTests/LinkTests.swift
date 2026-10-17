import Foundation
import Testing
@testable import KeyDimmerCore

struct LinkTests {
    private let displayLadder = Ladder.display()

    @Test func enablingTheLinkMovesTheKeyboardToTheDisplaysMatchingLevelAtOnce() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(displayLadder.shade(8)!, on: .display)
        controller.select(.system(step: 10))

        controller.isLinked = true

        #expect(controller.level == controller.ladder.ember(12))
    }

    @Test func theLinkIsOffByDefaultSoTheDisplayLeavesTheKeyboardAlone() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(.system(step: 10))

        controller.select(displayLadder.shade(1)!, on: .display)
        controller.select(.system(step: 4), on: .display)

        #expect(!controller.isLinked)
        #expect(controller.level == .system(step: 10))
    }

    /// Shade i of 8 lands on the ember at the same position among the 12 embers; step k on step k.
    @Test(arguments: [
        ("shade:1", "ember:1"), ("shade:4", "ember:6"), ("shade:8", "ember:12"),
        ("system:1", "system:1"), ("system:9", "system:9"), ("system:16", "system:16"),
    ])
    func underTheLinkSelectingADisplayLevelPutsTheKeyboardOnItsMatch(display: String, keyboard: String) {
        let rig = Rig()
        let controller = rig.launch()
        controller.isLinked = true
        rig.run(for: 1)

        controller.select(displayLadder.level(named: display)!, on: .display)
        rig.run(for: 2)

        #expect(controller.level == controller.ladder.level(named: keyboard))
        #expect(controller.isLinked)
    }

    @Test func aManualKeyboardChangeUnderTheLinkStaysUntilTheNextDisplayChangeTakesItBack() {
        let rig = Rig()
        let controller = rig.launch()
        controller.isLinked = true
        controller.select(.system(step: 6), on: .display)
        rig.run(for: 1)

        controller.step(by: 2)
        rig.run(for: 1)
        #expect(controller.level == .system(step: 8))
        #expect(controller.isLinked)

        controller.select(.system(step: 5), on: .display)
        rig.run(for: 1)
        #expect(controller.level == .system(step: 5))
    }

    @Test func steppingTheDisplayDownPastItsFloorTakesTheKeyboardFromTheDimmestStepToTheBrightestEmber() {
        let rig = Rig()
        let controller = rig.launch()
        controller.isLinked = true
        controller.select(.system(step: 2), on: .display)
        rig.run(for: 1)

        controller.step(.display, by: -1)
        rig.run(for: 1)
        #expect(controller.level == .system(step: 1))

        controller.step(.display, by: -1)
        rig.run(for: 2)
        #expect(controller.level(of: .display) == displayLadder.shade(8))
        #expect(controller.level == controller.ladder.ember(12))
    }

    @Test func theLinkIsRememberedAcrossLaunches() {
        let rig = Rig()
        let first = rig.launch()
        first.isLinked = true
        first.willQuit()

        let next = rig.launch()

        #expect(next.isLinked)
    }

    @Test(arguments: [Set<Light>([.keyboard]), Set<Light>([.display])])
    func theLinkDoesNothingUnlessThisMacHasBothLights(lights: Set<Light>) {
        let rig = Rig()
        let controller = rig.launch(with: lights)
        let commands = rig.backlight.commands

        controller.isLinked = true
        controller.select(displayLadder.shade(8)!, on: .display)
        rig.run(for: 2)

        #expect(!controller.isLinked)
        #expect(rig.store.object(forKey: "isLinked") == nil)
        #expect(rig.backlight.commands == commands)
    }

    @Test func whenTheDisplayStepsAsideFromAShadeTheLinkedKeyboardFollowsItToTheSystemStep() {
        let rig = Rig()
        let controller = rig.launch()
        controller.isLinked = true
        controller.select(displayLadder.shade(3)!, on: .display)
        rig.run(for: 2)

        rig.display.externalChange(to: 0.3)
        rig.run(for: 2)

        #expect(controller.level(of: .display) == .system(step: 5))
        #expect(controller.level == .system(step: 5))
    }

    @Test func whenAGammaAppRemovesTheDisplaysShadeTheLinkedKeyboardFollowsItToTheDimmestStep() {
        let rig = Rig()
        let controller = rig.launch()
        controller.isLinked = true
        rig.run(for: 1)
        controller.select(displayLadder.shade(3)!, on: .display)
        rig.run(for: 2)
        #expect(controller.level == controller.ladder.ember(4))

        controller.otherGammaAppLaunched(bundleIdentifier: "org.herf.Flux")
        rig.run(for: 2)

        #expect(controller.level(of: .display) == .system(step: 1))
        #expect(controller.level == .system(step: 1))
        #expect(controller.isLinked)
    }
}
