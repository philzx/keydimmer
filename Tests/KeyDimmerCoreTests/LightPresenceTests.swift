import Foundation
import Testing
@testable import KeyDimmerCore

extension Rig {
    /// Launches KeyDimmer on a Mac that has only the given lights.
    func launch(with lights: Set<Light>) -> LightController {
        let controller = LightController(
            keyboard: lights.contains(.keyboard) ? backlight : nil,
            display: lights.contains(.display) ? display : nil,
            clock: clock, store: store,
            secondsSinceLastInput: { [unowned self] in self.secondsIdle },
            hardwareModel: Self.model, osBuild: Self.build
        )
        if lights.contains(.keyboard) {
            backlight.observeBrightness { [clock, weak controller] value in
                _ = clock.after(0) { controller?.brightnessChanged(to: value) }
            }
        }
        controller.start()
        return controller
    }
}

struct LightPresenceTests {
    @Test func aMacWithBothLightsHasTheKeyboardThenTheDisplay() {
        let controller = Rig().launch(with: [.keyboard, .display])

        #expect(controller.lights == [.keyboard, .display])
        #expect(controller.has(.keyboard))
        #expect(controller.has(.display))
    }

    @Test func aMacWithOnlyAKeyboardBacklightHasOnlyTheKeyboardLight() {
        let controller = Rig().launch(with: [.keyboard])

        #expect(controller.lights == [.keyboard])
        #expect(!controller.has(.display))
    }

    @Test func aMacWithoutAKeyboardBacklightStillDimsItsBuiltInDisplay() {
        let rig = Rig()
        let controller = rig.launch(with: [.display])

        controller.select(index: 2, on: .display)

        #expect(controller.lights == [.display])
        #expect(!controller.has(.keyboard))
        #expect(controller.ladder(of: .keyboard) == nil)
        #expect(controller.level(of: .keyboard) == nil)
        #expect(controller.level(of: .display) == Ladder.display().shade(3))
        #expect(rig.display.gammaFactor < 1)
    }

    @Test func keyboardCommandsAndEventsDoNothingWithoutAKeyboardBacklight() {
        let rig = Rig()
        let controller = rig.launch(with: [.display])
        let storedBefore = rig.store.values.keys.sorted()

        controller.select(index: 3, on: .keyboard)
        controller.select(.system(step: 8))
        controller.step(.keyboard, by: 1)
        controller.recalibrate()
        controller.willSleep()
        controller.didWake()
        controller.brightnessChanged(to: 0.5)
        rig.run(for: 5)
        controller.willQuit()

        #expect(controller.level(of: .keyboard) == nil)
        #expect(!controller.isCalibrating)
        #expect(controller.pause == nil)
        #expect(rig.backlight.commands == 0)
        #expect(rig.store.values.keys.sorted() == storedBefore)
    }

    @Test func displayCommandsDoNothingWithoutABuiltInDisplay() {
        let rig = Rig()
        let controller = rig.launch(with: [.keyboard])

        controller.select(index: 0, on: .display)
        controller.step(.display, by: 1)
        controller.willQuit()

        #expect(controller.level(of: .display) == nil)
        #expect(rig.display.brightnessCommands + rig.display.gammaCommands == 0)
        #expect(rig.store.values["displayLevel"] == nil)
    }

    @Test func eachLightIsDrivenOnAMacWithBoth() {
        let rig = Rig()
        let controller = rig.launch(with: [.keyboard, .display])

        controller.select(.system(step: 8), on: .keyboard)
        controller.select(index: 2, on: .display)
        rig.run(for: 1)

        #expect(rig.backlight.brightness() == 0.5)
        #expect(rig.display.gammaFactor < 1)
    }
}
