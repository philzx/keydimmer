import Foundation
import Observation
import Testing
@testable import KeyDimmerCore

/// The menu reads the controller's properties through SwiftUI's observation, though each light
/// keeps its state in its own type.
struct ObservationTests {
    /// Whether reading `read` and then running `change` notifies an observer.
    private func notifies(_ read: @escaping () -> Void, when change: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var isSet = false }
        let notified = Flag()
        withObservationTracking(read) { notified.isSet = true }
        change()
        return notified.isSet
    }

    @Test func selectingAKeyboardLevelNotifiesTheMenu() {
        let rig = Rig()
        let controller = rig.launch()

        #expect(notifies({ _ = controller.level }) { controller.select(.system(step: 8)) })
    }

    @Test func selectingADisplayLevelNotifiesTheMenu() {
        let rig = Rig()
        let controller = rig.launch()

        #expect(notifies({ _ = controller.displayLevel }) { controller.select(index: 2, on: .display) })
    }

    @Test func holdingAnEmberUpdatesTheStatsTheMenuShows() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)

        #expect(notifies({ _ = controller.stats }) { rig.run(for: 2) })
    }

    @Test func pausingTheHoldNotifiesTheMenu() {
        let rig = Rig()
        let controller = rig.launch()
        controller.select(index: 3)
        rig.run(for: 2)

        #expect(notifies({ _ = controller.pause }) { controller.willSleep() })
    }

    @Test func turningOffInactivityNotifiesTheMenu() {
        let controller = Rig().launch()

        #expect(notifies({ _ = controller.followsInactivity }) { controller.followsInactivity = false })
    }

    @Test func anotherGammaAppNotifiesTheMenu() {
        let controller = Rig().launch()

        #expect(notifies({ _ = controller.shadesUnavailableReason }) {
            controller.otherGammaAppLaunched(bundleIdentifier: "com.example.tint", name: "Tint")
        })
    }
}
