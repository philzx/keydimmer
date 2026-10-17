import Carbon.HIToolbox
import Foundation

/// System-wide ⌃⌥↓ / ⌃⌥↑ to step the slider. Carbon hot keys need no Accessibility permission.
@MainActor
final class HotKeys {
    var onStep: ((Int) -> Void)?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? register() : unregister()
        }
    }

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

        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(UInt32(binding.keyCode), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
