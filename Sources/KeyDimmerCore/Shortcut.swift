/// A global shortcut: the configured modifiers (plus ⇧ for the display) with an arrow, stepping a
/// light's slider. The app registers these; the arrows and the ⇧ are fixed.
public struct Shortcut: Hashable, Sendable {
    public enum Arrow: Hashable, Sendable {
        case up
        case down
    }

    /// Stable hotkey identifier. 1 and 2 are the keyboard's, as before the display existed.
    public let id: UInt32
    public let arrow: Arrow
    /// Whether ⇧ is held on top of the configured modifiers.
    public let addsShift: Bool
    public let light: Light
    public let delta: Int

    /// The keyboard with modifiers + ↑/↓; the built-in display with modifiers + ⇧ + ↑/↓.
    public static let all: [Shortcut] = [
        Shortcut(id: 1, arrow: .down, addsShift: false, light: .keyboard, delta: -1),
        Shortcut(id: 2, arrow: .up, addsShift: false, light: .keyboard, delta: +1),
        Shortcut(id: 3, arrow: .down, addsShift: true, light: .display, delta: -1),
        Shortcut(id: 4, arrow: .up, addsShift: true, light: .display, delta: +1),
    ]
}
