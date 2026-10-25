# Changelog

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
