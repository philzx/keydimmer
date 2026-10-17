/// Other apps that write the display's gamma table. Shades stand down while one runs, so two apps
/// don't fight over the table and flicker. Lunar ships a similar list.
public enum GammaApps {
    private static let exact: [String: String] = [
        "org.herf.Flux": "f.lux",
        "fyi.lunar.Lunar": "Lunar",
        "fyi.lunar.LunarLite": "Lunar Lite",
        "pro.betterdisplay.BetterDisplay": "BetterDisplay",
        // Released builds use the first identifier, the current source the second.
        "me.guillaumeb.MonitorControl": "MonitorControl",
        "app.monitorcontrol.MonitorControl": "MonitorControl",
        "app.monitorcontrol.MonitorControlLite": "MonitorControl Lite",
        "com.lowtechguys.GammaDimmer": "Gamma Dimmer",
    ]

    /// These identifiers end in the major version, e.g. "ca.michelf.GammaControl.6".
    private static let versioned: [(prefix: String, name: String)] = [
        ("ca.michelf.GammaControl.", "Gamma Control"),
        ("ca.michelf.BlackLight.", "BlackLight"),
    ]

    /// The app's name if the bundle identifier is a known gamma app's, nil otherwise.
    public static func name(forBundleIdentifier id: String) -> String? {
        if let name = exact[id] { return name }
        for (prefix, name) in versioned where id.hasPrefix(prefix) {
            let version = id.dropFirst(prefix.count)
            if !version.isEmpty, version.allSatisfy(\.isNumber) { return name }
        }
        return nil
    }
}
