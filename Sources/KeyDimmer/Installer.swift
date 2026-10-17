import AppKit
import CryptoKit

/// Replaces the running app with a newer release and relaunches it. Installs made with Homebrew are
/// upgraded through `brew` so it keeps track of the version; everything else from the release zip.
enum Installer {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let caskroom = "/opt/homebrew/Caskroom/keydimmer"
    private static let brew = "/opt/homebrew/bin/brew"

    static var isHomebrewInstall: Bool {
        FileManager.default.fileExists(atPath: caskroom) && FileManager.default.isExecutableFile(atPath: brew)
    }

    static func install(_ release: UpdateChecker.Release) async throws {
        if isHomebrewInstall {
            try await run(brew, ["upgrade", "--cask", "keydimmer"])
        } else {
            try await replaceFromZip(release)
        }
    }

    /// Waits for this process to exit, opens the (new) app at the same path, then quits.
    @MainActor
    static func relaunch() {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - From the release zip

    private static func replaceFromZip(_ release: UpdateChecker.Release) async throws {
        let current = Bundle.main.bundleURL
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw Failure("No permission to replace \(current.path).")
        }
        // On the app's volume, so the final swap is a rename.
        let work = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true
        )
        defer { try? fileManager.removeItem(at: work) }

        let sums = try await download(release.checksums)
        let zipData = try await download(release.zip)
        let expected = String(decoding: sums, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .first { $0.count == 2 && $0[1] == release.zip.lastPathComponent }?[0]
        let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else { throw Failure("The download's checksum doesn't match.") }

        let zip = work.appendingPathComponent(release.zip.lastPathComponent)
        try zipData.write(to: zip)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let app = work.appendingPathComponent("KeyDimmer.app")
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version
        else { throw Failure("The download isn't KeyDimmer \(release.version).") }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        _ = try fileManager.replaceItemAt(current, withItemAt: app)
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Couldn't download \(url.lastPathComponent).")
        }
        return data
    }

    // MARK: - Processes

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // A file rather than a pipe: brew can print more than a pipe buffers before it exits.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let last = text.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            throw Failure("\((tool as NSString).lastPathComponent) failed: \(last)")
        }
    }
}
