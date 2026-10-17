import AppKit
import Observation

/// Asks GitHub once a day whether a newer release exists. The only network access KeyDimmer makes.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    private(set) var available: Release?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { checkIfDue() } else { available = nil }
        }
    }

    private enum Keys {
        static let enabled = "checksForUpdates"
        static let lastCheck = "lastUpdateCheck"
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/philzx/keydimmer/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var timer: Timer?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    func start() {
        // Unbundled builds (`swift run`) have no version to compare.
        guard current != nil else { return }
        checkIfDue(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.checkIfDue() }
        }
    }

    func openReleasePage() {
        if let available { NSWorkspace.shared.open(available.page) }
    }

    private func checkIfDue(force: Bool = false) {
        guard isEnabled, let current else { return }
        let last = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.interval else { return }
        defaults.set(Date(), forKey: Keys.lastCheck)

        Task {
            guard let release = await Self.fetchLatest(), Self.isNewer(release.version, than: current) else { return }
            if isEnabled { available = release }
        }
    }

    private static func fetchLatest() async -> Release? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, page: payload.html_url)
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2"); missing parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
