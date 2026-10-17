import AppKit

/// Reports every app running now, then each launch and quit, by bundle identifier. The controller
/// decides which ones conflict.
@MainActor
final class AppLaunchObserver {
    enum Event {
        case launched(String)
        case quit(String)
    }

    private var tokens: [NSObjectProtocol] = []

    init(_ handler: @escaping (Event) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let mapping: [(Notification.Name, (String) -> Event)] = [
            (NSWorkspace.didLaunchApplicationNotification, Event.launched),
            (NSWorkspace.didTerminateApplicationNotification, Event.quit),
        ]
        tokens = mapping.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier else { return }
                MainActor.assumeIsolated { handler(event(id)) }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { handler(.launched(id)) }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
    }
}
