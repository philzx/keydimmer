import CryptoKit
import Foundation

/// Other apps that write the display's gamma table. Shades stand down while one runs, so two apps
/// don't fight over the table and flicker. Bundle identifiers are kept as SHA-256 digests.
public struct GammaApps: Sendable {
    private let exact: Set<String>
    /// Identifiers that end in the app's major version ("….6"), digested without the number.
    private let versioned: Set<String>

    public init(exactDigests: Set<String>, versionedDigests: Set<String>) {
        exact = exactDigests
        versioned = versionedDigests
    }

    /// A list from plain identifiers; each of `versionedPrefixes` ends in ".".
    public init(identifiers: [String], versionedPrefixes: [String] = []) {
        self.init(
            exactDigests: Set(identifiers.map(Self.digest)),
            versionedDigests: Set(versionedPrefixes.map(Self.digest))
        )
    }

    public static let known = GammaApps(
        exactDigests: [
            "ae3f0edd9df8c750596bc912ef6824422ee6ad3c89c23c6f649c921768587c5e",
            "be3c4950671be86a1b9ce0970ab7cbc5b8c416bbf737d8afa79551a93c093bd6",
            "6730281ac8222590a71fc9e6bebf48a1bb647fc43a8df9cc9b7eebcf3c81a55a",
            "a822bcaa07f50c02798fdec30f936653ba80a4cd371cb672f266c8124a1542e8",
            "f03e2a01a4669cfbe765febb43572c9d0d0271805b10d1391efe2bf8abbf8ccc",
            "bc785e89536b14de6c01ee615026d424e1e3c63dec4c75c524ced14a05b20b5b",
            "2553e9846fbcc430190b34fe7347394224ef536147a58ae9adb4d80522ba5d25",
            "189926c0057fb487454f5afb1d24489ac716f749ef6c770f9bf6e249c29f2893",
        ],
        versionedDigests: [
            "f8404c62817270194ea728363f6e805ed9e97e53da1020a5adc8329f0ecc5b09",
            "89349c09ca2c61a2cecb4460b9cec3d086b83e1da19c5f0b7161c8419f2d8c10",
        ]
    )

    public func contains(bundleIdentifier id: String) -> Bool {
        if exact.contains(Self.digest(id)) { return true }
        guard let dot = id.lastIndex(of: ".") else { return false }
        let version = id[id.index(after: dot)...]
        guard !version.isEmpty, version.allSatisfy(\.isNumber) else { return false }
        return versioned.contains(Self.digest(String(id[...dot])))
    }

    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
