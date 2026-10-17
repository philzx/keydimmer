---
status: accepted
---

# Shades are made with gamma tables, not an overlay window

Shades darken a display by scaling its gamma transfer table rather than drawing a translucent black window over it. Gamma isn't captured in screenshots or recordings, doesn't dim the cursor, and can't be covered by full-screen apps; the cost is that it collides with ColorSync profiles and other gamma apps, so KeyDimmer turns shades off when another gamma app is running.

## Consequences

Measured on a 15" M4 MacBook Air with the `prototype/display-shades` probe:

- **The built-in display has no embers.** Its floor (≈2.06 nits) is already reached at the first macOS step; the continuous slider and both linear-brightness APIs clamp there, 0 switches the backlight off, and a fade to 0 jumps straight down without passing below the floor. Shades are the only way below it.
- **Night Shift composes with shades** — it doesn't touch the gamma table, and the display is visibly dimmed and warm at once.
- **macOS restores the gamma when the process dies**, so a crash can't leave the display dark and no "panic gesture" is needed.
- A shade held for 5 minutes, across locking and unlocking the screen, showed no flicker.
