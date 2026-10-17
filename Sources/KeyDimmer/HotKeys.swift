import Carbon.HIToolbox
import Foundation

/// System-wide modifier + ↓ / ↑ to step the slider. Carbon hot keys need no Accessibility permission.
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
    }

    var onStep: ((Int) -> Void)?

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

    /// True when macOS refused one of the shortcuts, usually because another app holds it. Both are
    /// then left unregistered rather than half working.
    private(set) var registrationFailed = false

    private static let signature: OSType = 0x4B44_4D52 // 'KDMR'
    private static let bindings: [(id: UInt32, keyCode: Int, delta: Int)] = [
        (1, kVK_DownArrow, -1),
        (2, kVK_UpArrow, +1),
    ]

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == HotKeys.signature,
                  let binding = HotKeys.bindings.first(where: { $0.id == id.id }) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKeys.onStep?(binding.delta) }
            return noErr
        }, 1, &spec, context, &handler)

        var failed = false
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(UInt32(binding.keyCode), UInt32(modifiers.carbon), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed = true }
        }
        if failed { unregister() }
        registrationFailed = failed
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        registrationFailed = false
    }
}
