<p align="center"><img src="docs/icon.png" width="128" alt="KeyDimmer icon"></p>

# KeyDimmer

**Below the bottom step.** A menu bar app that takes an Apple Silicon Mac's keyboard backlight and
built-in display *below* the dimmest level macOS allows — steadily, without the pulsing other tools
accept — and hands control back to macOS above it.

<p align="center"><img src="docs/menu.png" width="320" alt="KeyDimmer menu"></p>

## What it does

- **Keyboard: 12 embers below the floor**, then all 16 macOS steps, on one slider (arrow keys step
  through it while the menu is open).
- **Display: 8 shades below the floor**, then all 16 macOS steps. The backlight can't go below its
  dimmest step, so shades darken the picture on top of it. The darkest stays readable, and there's
  no off position.
- **Calibrated to your Mac.** The floor macOS can reach differs between models (54/960 duty on a
  15" M4 MacBook Air). KeyDimmer measures it once and spreads the embers from 1 count up to ~80% of
  that floor, so there is no gap between the brightest ember and macOS's first step.
- **Steady hold.** The light is kept inside a single PWM count. Measured on hardware: 99.7–100%
  of 20 Hz samples exactly on target at duties of 1, 3, 12, 20 and 43 / 960.
- **Link (optional).** The keyboard follows the display: a shade puts it on a matching ember, a
  macOS step on the same macOS step. You can still nudge the keyboard by hand.
- **Global shortcuts** ⌃⌥↑ / ⌃⌥↓ for the keyboard, ⌃⌥⇧↑ / ⌃⌥⇧↓ for the display (no Accessibility
  permission needed).
- **Respects macOS.** Follows your "turn keyboard backlight off after inactivity" setting, goes dark
  on sleep and with the lid closed, steps aside the moment you change brightness with the keys or
  Control Center, and hands automatic brightness back exactly as it found it — even after a crash.
  Shades work with Night Shift, stay on at the lock screen, and stand down while another gamma app
  (f.lux, Lunar, BetterDisplay, MonitorControl…) is running.
- **Leaves things tidy.** Quitting on an ember or a shade leaves that light at the dimmest level
  macOS can keep on its own. If KeyDimmer crashes, macOS restores the picture.
- No accounts or analytics. The only network access is a daily check for new releases on GitHub,
  which you can turn off in the menu. ~0% CPU while holding.

Requires an Apple Silicon Mac and macOS 14 or later. KeyDimmer shows only the lights your Mac has: a
backlit keyboard, a built-in display, or both. External displays aren't supported yet.

## Install

```sh
brew install --cask philzx/tap/keydimmer
```

Or download the latest `.dmg` from [Releases](https://github.com/philzx/keydimmer/releases/latest), open
it and drag KeyDimmer to Applications.

KeyDimmer isn't notarised by Apple, so macOS blocks it the first time you open it. Go to
**System Settings → Privacy & Security** and click **Open Anyway** — only needed once. Or, in
Terminal: `xattr -dr com.apple.quarantine /Applications/KeyDimmer.app`. (Homebrew installs skip this.)

KeyDimmer checks GitHub daily and offers updates in its menu; it installs them itself, or through
`brew upgrade` if Homebrew installed it.

## How it works

macOS clamps every non-zero keyboard brightness to a hardware floor, but a fade towards 0 passes
through every PWM duty below it. KeyDimmer uses CoreBrightness's private `KeyboardBrightnessClient`
to start fades and reads the actual duty (`high-period` of the `kbd-backlight` IOKit service).

Each fade is linear and takes a fixed time set by its speed (≈41 s at the slowest), whatever the
distance. The [hold engine](Sources/KeyDimmerCore/HoldEngine.swift):

1. **Approaches** the target with a quick fade, polling the duty every 4 ms, and syncs a model of
   the hidden fade position when the duty crosses a known count boundary.
2. **Holds** by alternating very slow fades down and up, reversing when the modelled position is
   0.2 counts either side of the centre of the target count — so the integer duty never changes.
3. **Resyncs** if a 1 Hz watchdog read disagrees with the model.

The built-in display has no such loophole: below its dimmest step the backlight switches off. A shade
sets the display to that step and scales its gamma table by a factor (geometric from 12% up to 90%
of the original picture; [ADR-0003](docs/adr/0003-shades-via-gamma-tables.md)). Every rule for both
lights lives in one [controller](Sources/KeyDimmerCore/LightController.swift), tested against
simulated hardware.

## Build

```sh
./scripts/build-app.sh          # → build/KeyDimmer.app (ad-hoc signed)
open build/KeyDimmer.app
```

`VERSION=1.2.0 ./scripts/package.sh` also builds `dist/KeyDimmer-1.2.0.dmg` and `.zip`. Pushing a
`v*` tag does the same on GitHub Actions and publishes a release.

Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution (notarise afterwards).

```sh
swift test                      # controller and hold engine against simulated hardware
swift run kdctl info            # backlight state
swift run kdctl hold 5 60       # hold duty 5/960 for 60 s and report stability
swift run kdctl display info    # display brightness, measured nits, gamma peak
swift run kdctl display shade 0.5 20  # hold a shade for 20 s, report outside gamma changes
```

`KEYDIMMER_TRACE=1 build/KeyDimmer.app/Contents/MacOS/KeyDimmer` prints the engine's syncs and drifts.
`KeyDimmer --snapshot out.png ember:4 display:shade:3` renders the menu (dark and light) without
touching the lights.

## Layout

| Path | |
| --- | --- |
| `Sources/KeyDimmerCore` | Light controller, hardware access, ladders, floor probe and hold engine (UI-free, tested) |
| `Sources/KeyDimmer` | SwiftUI menu bar app |
| `Sources/kdctl` | Diagnostics CLI |
| `Tests/KeyDimmerCoreTests` | Controller and engine tests against simulated hardware |
| `GLOSSARY.md`, `docs/adr` | Vocabulary and design decisions |
