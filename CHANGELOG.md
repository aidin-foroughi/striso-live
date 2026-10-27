# Changelog

## 1.4.0 (unreleased)

Needs board firmware v2.2.4-338-93 or newer (next5 1532ce2: the key layout StcG, the config Stcc, presets, StcW,
the dials StcT, the voice keys, the engine slots, Mono, midikey). Voices are selected only with
StcW, so with an older firmware voice changes don't go through. There is no fallback for it.

- **The keys as the board reports them.** The board view, the note names, the tuning labels, the
  chord readout and the key equalizer take the keys from the firmware's key layout (StcG): which
  button each key is, its place and its name. The app keeps no copy of the firmware's tables; it
  remembers the last board's reply, so the board is drawn at the next start before one connects.
- **Save to Striso writes the firmware's own config.** The board builds the config to save
  (Stcc: its settings with the touch settings, key factors and voice keys it plays now); the app
  only copies it to the update drive, after a backup. The app's own config writer is gone.
- **No demo mode.** Virtual, the firmware on this computer, is the demo; the Dart mock board,
  `--mock-demo` and the demo labels are gone. `--demo` is now `--virtual`. The tuning menu lists
  the board's own tunings (StcX) for any board that plays.

- **A quieter UI.** The explanatory sentences under Audio, MIDI out, the key equalizer's meter,
  the preset dialogs and the save dialog are gone or became tooltips; a firmware without a
  preset store shows no ON THE STRISO section. Buttons and toggles are in the Tab order (Enter or
  Space presses them, with the design's focus ring); selects light up under the pointer. At 1000
  to 1279 px the engine row keeps nine engines on one line, the toolbar's right end shows the
  sound name (the hover readout while a key is under the pointer), and the harmony strip's
  middle keeps its numeral and never overflows; the Sound tab's name no longer shares its room
  with a spacer. A voice row left waiting for a board that went away is no longer pending for
  ever; the hover readout is blank without a board. `test/sizes_test.dart` walks every tab, mode
  and overlay at 1000x700, 1280x800 and 1600x1000, then unplugs the board and plugs it back.

- **Shared audio output by default.** Exclusive output was the default, and it played at full
  level whatever the Windows volume said. The output is now shared; Exclusive output is an
  opt-in, with a one-time warning, and it applies the Windows volume itself. Settings from before
  turn shared once.

- **Presets on the Striso.** Under the engine's presets, ON THE STRISO lists your own presets on
  the board.
  - **Save as…** takes a title and a description, and the board writes the preset.
  - **Share…** saves any preset as a `.json` file, factory ones included.
  - **Install…** sends a preset file to the board as it is; you can also drop files on the window.
  - **Load** plays it. A preset made for another version of the engine loads with the board's
    report of what it clamped and skipped.
- **Engines in the board's slots.** An awva engine is one package (`.awvapkg`) for every board.
  Setup lists the engine slots of the board that plays, Virtual's or the Striso's, as its
  firmware reports them; **Put on …** sends a package from the engine library with the
  firmware's progress, and **Erase** frees a slot. Virtual starts again with the engine on its
  first voice; the Striso takes it at its next start. This replaces 1.3.0's engines ticked onto
  a build: an engine reaches Virtual only through its slots.
- **Voice select by StcW.** It reaches any entry of the voice list.
- **Any engine on any voice key.** Setup, Settings keys: click a voice key to choose the engine
  on it and the preset it starts on, put its own engine back (↺), or leave it empty. Three free
  keys (10, 12, 14) take new engines. Right-click an engine button to **Put on key…**, with the
  free keys first; putting it in place of another engine offers Undo. A key whose engine isn't
  loaded shows that and stays dark. Changes are live; **Save to Striso** keeps them, in the
  board's own settings records. Needs the firmware with the voice keys (Stca, StcA).
- **MIDI out in Setup.** The board's MIDI settings (channel, voices, bend range, volume,
  sustain, rate, fine tuning) as sliders, in the ranges the board lists (StcT), set on the board.
- **The MIDI monitor** in the console: what the board receives and sends.

## 1.3.0

Needs firmware v2.2.4-231 or newer
([striso-control-firmware](https://github.com/aidin-foroughi/striso-control-firmware)), a firmware
that reports its settings layout, its state and its hero knobs (StcX, StcY, StcH). An older
firmware gets "This Striso needs a firmware update" with its version and what to do; there is no
fallback for it. Virtual needs a `striso_virtual` build of C API 2.

- **Two instruments in the header.** Striso is your board over USB, and Virtual is the Striso
  firmware running on the computer, played from MIDI controllers and the on-screen board. A switch
  ends one completely before the other starts, as Disconnect does.
- **The build chooser.** A click on Virtual lists the firmware builds in the firmware folder:
  - each by its title and description, with the commit it runs;
  - the one on your Striso marked;
  - the ones that can't load greyed, with the reason.

  Choosing a build plays it on the same voice key, and ⇄ goes back to the one before.
- **Builds and engines as sounds.** Install a build or an engine… takes a firmware release zip or
  an awva engine (the library and its manifest). Tick an engine and it's loaded with the build
  that plays, after the build's own voices. ⇄ goes between the build with and without it.
- **Fixes with buttons.** A problem comes with the buttons that fix it: Pick a build, Install a
  release zip, Get the runtime, Clear quarantine, Copy version, Play Virtual.
- **Legato.** Mono legato on the firmware, switched from the Play tab (settings key 9), as the
  board reports it.
- **MIDI 2.0 inputs.** Through Windows MIDI Services and CoreMIDI, straight to the firmware.
  MIDI 1.0 controllers keep working.
- **One device, one input.** A controller that shows up both as a MIDI 2.0 and as a MIDI 1.0
  port is listed once.
- **No runtime to install on Windows.** The Microsoft C++ runtime ships inside the app.
- **macOS 11 or later**, Apple silicon and Intel in one app.

## 1.2.0

Through PC and Record.

## 1.1.0

Releases for Windows and macOS, and the one-line installers.
