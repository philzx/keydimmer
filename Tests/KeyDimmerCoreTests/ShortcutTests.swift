import Testing
@testable import KeyDimmerCore

struct ShortcutTests {
    @Test func theKeyboardKeepsModifiersAndArrowsWhileTheDisplayAddsShift() {
        let table = Set(Shortcut.all.map { "\($0.arrow) shift:\($0.addsShift) \($0.light) \($0.delta)" })
        #expect(table == [
            "down shift:false keyboard -1",
            "up shift:false keyboard 1",
            "down shift:true display -1",
            "up shift:true display 1",
        ])
    }

    @Test func everyShortcutHasItsOwnIdentifier() {
        #expect(Set(Shortcut.all.map(\.id)).count == Shortcut.all.count)
    }

    @Test func theKeyboardShortcutsKeepTheirIdentifiers() {
        // Ids 1 (↓) and 2 (↑) predate the display; keeping them leaves the keyboard's shortcuts as they were.
        let one = Shortcut.all.first { $0.id == 1 }
        let two = Shortcut.all.first { $0.id == 2 }
        #expect(one?.light == .keyboard && one?.delta == -1 && one?.addsShift == false)
        #expect(two?.light == .keyboard && two?.delta == 1 && two?.addsShift == false)
    }
}
