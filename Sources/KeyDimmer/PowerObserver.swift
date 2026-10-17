import AppKit

/// Sleep and display-sleep transitions, folded into "the backlight must go dark" and "it may return".
@MainActor
final class PowerObserver {
    enum Event {
        case willSleep
        case didWake
    }

    private var tokens: [NSObjectProtocol] = []

    init(_ handler: @escaping (Event) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let mapping: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.screensDidSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidWakeNotification, .didWake),
        ]
        tokens = mapping.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
    }
}
