import AppKit
import Carbon.HIToolbox
import KeyDimmerCore

/// System-wide modifier + ↓ / ↑ to step the keyboard's slider, and modifier + ⇧ + ↓ / ↑ for the
/// built-in display's, repeating while held like any other key. Carbon hot keys need no
/// Accessibility permission.
@MainActor
final class HotKeys {
    /// The modifier pairs on offer; the arrows themselves are fixed.
    enum Modifiers: String, CaseIterable, Identifiable {
        case controlOption
        case controlCommand
        case optionCommand
        case controlOptionCommand

        var id: Self { self }

        var symbols: String {
            switch self {
            case .controlOption: return "⌃⌥"
            case .controlCommand: return "⌃⌘"
            case .optionCommand: return "⌥⌘"
            case .controlOptionCommand: return "⌃⌥⌘"
            }
        }

        fileprivate var carbon: Int {
            switch self {
            case .controlOption: return controlKey | optionKey
            case .controlCommand: return controlKey | cmdKey
            case .optionCommand: return optionKey | cmdKey
            case .controlOptionCommand: return controlKey | optionKey | cmdKey
            }
        }

        fileprivate var flags: NSEvent.ModifierFlags {
            switch self {
            case .controlOption: return [.control, .option]
            case .controlCommand: return [.control, .command]
            case .optionCommand: return [.option, .command]
            case .controlOptionCommand: return [.control, .option, .command]
            }
        }
    }

    var onStep: ((Light, Int) -> Void)?

    /// The lights to register shortcuts for: a Mac without a display light leaves its keys free.
    var lights: Set<Light> = [.keyboard] {
        didSet {
            guard lights != oldValue, isEnabled else { return }
            unregister()
            register()
        }
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? register() : unregister()
        }
    }

    var modifiers: Modifiers = .controlOption {
        didSet {
            guard modifiers != oldValue, isEnabled else { return }
            unregister()
            register()
        }
    }

    /// The lights whose shortcuts macOS refused, usually because another app holds them. A light's
    /// ↑ and ↓ are then both left unregistered rather than half working; the other light's still work.
    private(set) var failedLights: Set<Light> = []

    private static let signature: OSType = 0x4B44_4D52 // 'KDMR'

    private var refs: [Light: [EventHotKeyRef]] = [:]
    private var handler: EventHandlerRef?
    /// Carbon reports a press once, never as repeats, so holding the keys is timed here.
    private var repeatTimer: Timer?

    private func register() {
        var specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == HotKeys.signature,
                  let shortcut = Shortcut.all.first(where: { $0.id == id.id }) else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { pressed ? hotKeys.pressed(shortcut) : hotKeys.stopRepeating() }
            return noErr
        }, specs.count, &specs, context, &handler)

        var failed: Set<Light> = []
        for shortcut in Shortcut.all where lights.contains(shortcut.light) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: shortcut.id)
            let keyCode = shortcut.arrow == .up ? kVK_UpArrow : kVK_DownArrow
            let carbon = modifiers.carbon | (shortcut.addsShift ? shiftKey : 0)
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(carbon), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[shortcut.light, default: []].append(ref) } else { failed.insert(shortcut.light) }
        }
        failed.forEach(unregister)
        failedLights = failed
    }

    /// Steps once, then again after the system's key repeat delay and at its repeat rate until released.
    private func pressed(_ shortcut: Shortcut) {
        onStep?(shortcut.light, shortcut.delta)
        schedule(after: NSEvent.keyRepeatDelay) { [weak self] in self?.repeatStep(shortcut) }
    }

    private func repeatStep(_ shortcut: Shortcut) {
        // A release isn't always reported when the modifiers come up before the arrow.
        let flags = shortcut.addsShift ? modifiers.flags.union(.shift) : modifiers.flags
        guard NSEvent.modifierFlags.contains(flags) else { return stopRepeating() }
        onStep?(shortcut.light, shortcut.delta)
        schedule(after: NSEvent.keyRepeatInterval) { [weak self] in self?.repeatStep(shortcut) }
    }

    private func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated(action) }
        // .common so it keeps firing while the menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func unregister() {
        stopRepeating()
        refs.keys.forEach(unregister)
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        failedLights = []
    }

    private func unregister(_ light: Light) {
        refs[light]?.forEach { UnregisterEventHotKey($0) }
        refs[light] = nil
    }
}
