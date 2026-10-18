import Foundation
import Observation

/// The built-in display's state and rules: shades on top of its floor, darkening the picture's
/// gamma, standing aside for brightness changes and other gamma apps, and taking the shade off for
/// display sleep. `LightController` routes commands and events here.
@Observable
final class BuiltInDisplayLight {
    /// The shades, then macOS's steps.
    let ladder = Ladder.display()
    /// Nil until started.
    ///
    /// Every change of the level, whoever causes it, passes through here and is reported to
    /// `onLevelChange`. The first reading at launch isn't a change.
    private(set) var level: Level? {
        didSet { if oldValue != nil, level != oldValue { onLevelChange?() } }
    }

    /// Whether shades can be selected; off while another gamma app is running. Turning it off
    /// moves a shade to the floor.
    var shadesAreAvailable = true {
        didSet { if !shadesAreAvailable, level?.isShade == true { select(Self.floor) } }
    }

    @ObservationIgnored var onLevelChange: (() -> Void)?
    @ObservationIgnored var onTrace: ((String) -> Void)?

    enum Keys {
        static let level = "displayLevel"
        /// The display's automatic brightness as found before the first shade; present only while
        /// on shades, so a crash on a shade leaves it for the next launch to hand back.
        static let autoBrightnessToRestore = "displayAutoBrightnessToRestore"
    }

    /// The display's floor: the dimmest macOS step. Shades are applied on top of it.
    private static let floor = Level.system(step: 1)
    private static let floorBrightness = Level.systemBrightness(step: 1)

    @ObservationIgnored private let hardware: DisplayHardware
    @ObservationIgnored private let clock: EngineClock
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let autoBrightness: AutoBrightnessRecord
    /// Whether the display's gamma table is one of our shades.
    @ObservationIgnored private var isShaded = false
    /// The shade taken off for sleep, to put back on wake.
    @ObservationIgnored private var sleepingShade: Level?
    @ObservationIgnored private var wake: Cancellable?

    init(hardware: DisplayHardware, clock: EngineClock, store: SettingsStore) {
        self.hardware = hardware
        self.clock = clock
        self.store = store
        autoBrightness = Self.autoBrightnessRecord(in: store)
    }

    static func autoBrightnessRecord(in store: SettingsStore) -> AutoBrightnessRecord {
        AutoBrightnessRecord(store: store, key: Keys.autoBrightnessToRestore)
    }

    // MARK: - Lifecycle

    /// Returns to the saved shade (macOS restored the picture when the last run ended), or shows
    /// the step macOS is at.
    func start() {
        hardware.observeBrightness { [weak self, clock] _ in
            _ = clock.after(0) { self?.brightnessChanged() }
        }
        let saved = (store.object(forKey: Keys.level) as? String).flatMap(ladder.level(named:))
        // A crash on a shade left automatic brightness paused, unless we're returning to a shade.
        if saved?.isShade != true { releaseAutoBrightness() }
        if let saved, saved.isShade {
            // Another gamma app is already running: the shade stands down to the floor, as it would have.
            select(shadesAreAvailable ? saved : Self.floor)
        } else {
            level = ladder.nearestLevel(forBrightness: hardware.brightness())
        }
    }

    /// Leaves the display as dim as macOS can keep it without us: the floor, with the picture back.
    func willQuit() {
        guard level?.isShade == true else { return }
        restoreGamma()
        setBrightness(Self.floorBrightness)
        releaseAutoBrightness()
    }

    // MARK: - Selection

    func select(_ newLevel: Level) {
        guard ladder.index(of: newLevel) != nil, !(newLevel.isShade && !shadesAreAvailable) else { return }
        trace("select display \(newLevel.title)")
        level = newLevel
        store.set(newLevel.storageName, forKey: Keys.level)
        apply(newLevel)
    }

    /// Drives the display to a level: a shade is the floor with the picture darkened, a system step
    /// is macOS's own brightness with the picture as ColorSync wants it.
    private func apply(_ level: Level) {
        switch level {
        case let .shade(_, factor):
            // Automatic brightness would move the backlight off the floor under the shade.
            autoBrightness.takeOver(isEnabled: hardware.isAutoBrightnessEnabled, set: hardware.setAutoBrightness)
            setBrightness(Self.floorBrightness)
            hardware.setGamma(factor: factor)
            isShaded = true
        case let .system(step):
            restoreGamma()
            setBrightness(Level.systemBrightness(step: step))
            releaseAutoBrightness()
        case .off, .ember:
            break // Not on the display's ladder.
        }
    }

    /// Only commands a change, so moving between shades leaves the backlight alone.
    private func setBrightness(_ value: Float) {
        guard hardware.brightness() != value else { return }
        hardware.setBrightness(value)
    }

    /// Only touches the gamma if a shade of ours is applied: any other table (ColorSync's, or
    /// another app's) is left as it is.
    private func restoreGamma() {
        guard isShaded else { return }
        hardware.restoreGamma()
        isShaded = false
    }

    private func releaseAutoBrightness() {
        autoBrightness.handBack(set: hardware.setAutoBrightness)
    }

    /// macOS reports every brightness change, possibly including our own sets, and a stale echo
    /// can arrive after we've moved on, so the display's brightness right now is what counts, not
    /// the reported value. On a shade, anything but the floor means someone else (the brightness
    /// keys, Control Center, another app) took over: step aside and follow them. On a system step,
    /// the slider just follows. While the shade is off for sleep, until the wake grace is over,
    /// macOS and the panel move the brightness themselves, so ignore it: the wake puts
    /// the shade back on the floor.
    private func brightnessChanged() {
        guard let current = level, sleepingShade == nil else { return }
        let brightness = hardware.brightness()
        trace("display brightness notification \(brightness)")
        let level = ladder.nearestLevel(forBrightness: brightness)
        if current.isShade {
            guard abs(brightness - Self.floorBrightness) > 0.001 else { return }
            restoreGamma()
            releaseAutoBrightness()
        } else if level == current {
            return
        }
        self.level = level
        store.set(level.storageName, forKey: Keys.level)
    }

    // MARK: - Sleep

    /// Takes the shade off for sleep, remembering it so waking can put it back.
    func willSleep() {
        wake?.cancel()
        wake = nil
        guard let level, level.isShade else { return }
        trace("sleep display")
        restoreGamma()
        sleepingShade = level
    }

    /// Puts the shade back after the wake grace, unless the level changed in the meantime.
    func didWake() {
        guard sleepingShade != nil else { return }
        wake?.cancel()
        wake = clock.after(LightController.wakeGrace) { [weak self] in
            guard let self, let shade = self.sleepingShade else { return }
            self.sleepingShade = nil
            self.wake = nil
            guard self.level == shade else { return }
            self.trace("wake display")
            self.apply(shade)
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard let onTrace else { return }
        onTrace(message())
    }
}
