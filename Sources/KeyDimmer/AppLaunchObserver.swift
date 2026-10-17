import AppKit
import KeyDimmerCore

/// Reports the other gamma apps (`GammaApps.known`) running now, then each launch and quit.
@MainActor
final class AppLaunchObserver {
    enum Event {
        case launched(bundleIdentifier: String, name: String)
        case quit(bundleIdentifier: String)
    }

    private var tokens: [NSObjectProtocol] = []

    init(_ handler: @escaping (Event) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let mapping: [(Notification.Name, (NSRunningApplication) -> Event?)] = [
            (NSWorkspace.didLaunchApplicationNotification, Self.launched),
            (NSWorkspace.didTerminateApplicationNotification, { Self.gammaApp($0).map(Event.quit) }),
        ]
        tokens = mapping.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let event = event(app) else { return }
                MainActor.assumeIsolated { handler(event) }
            }
        }
        NSWorkspace.shared.runningApplications.compactMap(Self.launched).forEach(handler)
    }

    /// The app's bundle identifier if it's a known gamma app.
    private nonisolated static func gammaApp(_ app: NSRunningApplication) -> String? {
        app.bundleIdentifier.flatMap { GammaApps.known.contains(bundleIdentifier: $0) ? $0 : nil }
    }

    private nonisolated static func launched(_ app: NSRunningApplication) -> Event? {
        gammaApp(app).map { .launched(bundleIdentifier: $0, name: app.localizedName ?? $0) }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
    }
}
