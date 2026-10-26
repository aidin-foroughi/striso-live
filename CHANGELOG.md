# Changelog

## 1.4.0 (unreleased)

Needs the board firmware next2 or newer (presets, StcW, the dials StcT, the voice keys, the
engine slots). Voices are selected only with StcW, so with an older firmware voice changes don't
go through. There is no fallback for it.

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
