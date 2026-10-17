# KeyDimmer

A menu bar app that keeps a Mac's lights below the dimmest level macOS allows, steadily, and hands control back to macOS above it.

## Language

### Lights

**Light**:
Something KeyDimmer can dim: the keyboard backlight, the built-in display, or one external monitor. Each light has its own floor and ladder.
_Avoid_: Device, target, output, display (for the keyboard)

**Link**:
An optional pairing in which the keyboard follows the built-in display: a display on a shade puts the keyboard on an ember, a display on a system step puts it on a system step. The display leads; adjusting the keyboard by hand doesn't break the link.
_Avoid_: Sync, master slider, group

### Brightness

**Level**:
One position on a slider: off, an ember, a shade, or a system step.
_Avoid_: Setting, value, position

**Floor**:
The dimmest non-zero brightness macOS (or the device itself) will hold on its own.
_Avoid_: Minimum, bottom step

**System step**:
A level macOS can reach and hold by itself, at or above the floor.
_Avoid_: macOS level, native level

**Ember**:
A level below the floor reached by genuinely dimming the hardware's light, held by KeyDimmer because macOS won't.
_Avoid_: Sub-zero, sub-minimum level

**Shade**:
A level below the floor reached by darkening the picture in software while the hardware's light stays where it is; it costs contrast, unlike an ember.
_Avoid_: Ember (for software dimming), sub-zero, gamma dimming

**Ladder**:
The ordered list of levels a slider moves through, from off up to the brightest system step.
_Avoid_: Scale, steps

### Behaviour

**Hold**:
Keeping a light steadily on a level macOS would not keep it on by itself.
_Avoid_: Lock, pin
