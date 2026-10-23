# Striso Live (desktop)

The live companion for the Striso board as a Flutter desktop app for Windows and macOS. It
replaces the Electron build of `tools/app`; the web app and Electron stay in the repo until this
app has been played with for a while.

It shows the playing on the real key layout (pressure, tilt, strikes, motion), browses voices and
presets, edits the live parameters (voice and effects) with undo, mutate and a morph pad, keeps
your own sounds, names chords with roman numerals and a progression strip, highlights scales,
shows what every key does in the Striso's settings mode, and evens out the keys (touch settings,
key equalizer with a live pressure meter and Suggest) and saves those to the board.

USB goes through libusb-1.0 directly (no browser, no WebUSB device chooser): on this PC the app
is live about 0.3 s after it starts talking to the board.

## Run it

### Windows

1. Unzip `StrisoLive-1.1.0-windows-x64.zip` anywhere and run `Striso Live\StrisoLive.exe`.
2. The build is not signed, so SmartScreen may say *Windows protected your PC*: click
   **More info**, then **Run anyway**. Windows remembers it for this file.
3. Plug in the Striso and click **Connect** (or **Try the demo** without a board).

The installer (`StrisoLive-1.0.0-setup.exe`, from CI) installs per user without admin rights and
gets the same SmartScreen warning.

The Striso's USB interface 2 must use the WinUSB driver (the board asks for it itself; if
Connect says there is no usable driver, the Zadig tool can set WinUSB for *Striso, interface 2*).

### macOS

1. Unzip `StrisoLive-1.0.0-macos.zip` and move **Striso Live.app** to Applications.
2. The app is signed ad hoc only, so Gatekeeper refuses a double-click the first time:
   right-click the app, choose **Open**, then **Open** again. Or in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Striso Live.app"`.
3. libusb is inside the app (`Contents/Frameworks/libusb-1.0.0.dylib`). The app is not
   sandboxed: it needs USB and it writes the settings to the Striso's update drive in /Volumes.

### Good to know

- **One program at a time.** Only one program can hold the Striso's interface. If Connect says
  the board is busy, close the web app tab, the Electron app or a `tools/striso.py` session.
- **Reconnects by itself** after an unplug or a reboot, 4 s after the board is back (so a flash
  tool gets it first), retrying a busy board for 30 s; never after you clicked Disconnect.
  At start it connects right away when you left it connected.
- **Your data** lives in `%APPDATA%\Striso Live` (Windows) or
  `~/Library/Application Support/Striso Live` (macOS): `settings.json` (preferences, your sounds,
  morph corners), `logs/striso-live.log` (also in the console drawer) and `backups/` (the board's
  previous settings, saved before every Save to Striso).
- **Errors** never open a native dialog: they go to the console drawer and the log file.

### Save to Striso

Writes the touch settings and key factors into the board's settings (preset 1, loaded at
power-on). The app puts the board into its update mode, lets go of it, then: uses only a drive
whose `INFO_UF2.TXT` names the Striso (and only when there is exactly one), backs up its
`CONFIG.UF2`, writes `NEWCFG.UF2` whose blocks all lie inside the config area
0x08020000-0x08040000 and read back as the intended records (the same bytes as
`tools/striso.py save_touch`), waits for the restart, reconnects and reads the values back.

### Layout

- **Play**: the engine row (the Striso's voice-key colours), this engine's presets and your
  sounds; the board with key, scale (66 scales in groups, searchable, with degree formulas) and
  labels; the chord, roman numeral, progression and key; the hero knobs of the voice (per engine
  and preset, by the firmware's parameter names) and the reverb and delay amounts.
- **Sound**: every voice and effect parameter, undo/redo, Reset, Mutate, A/B, Save sound, Copy as
  C; My sounds; the morph pad (closed until you open it).
- **Setup**: Sensitivity, Key equalizer or Settings keys on the big board; Save to Striso;
  motion; firmware.
- **Stage mode** (F or F11, Esc leaves): only the board and the chord, larger.
- After a reconnect, if the board lost your edits (a restart, Save to Striso), a toast offers to
  restore the edited sound.

### Keys

`1`-`7` engines, `[` `]` previous/next preset, `Ctrl+1/2/3` tabs, `Ctrl+Z`/`Ctrl+Y` undo/redo,
`Ctrl+S` save the sound, `M` mutate, `B` (hold) A/B, `F`/`F11` stage, `` ` `` console, `S`
settings keys, `?` all of these. Knobs: drag (Shift: fine), scroll, arrow keys; double-click
resets; Alt+click locks against Mutate.

### Command line

| flag | |
|---|---|
| `--demo` | start with the simulated board |
| `--no-usb` | never touch USB |
| `--fake-save[=fail]` | Save to Striso runs every step except the drive (works in the demo) |
| `--hidden` | Windows: the window starts minimized and off-screen |
| `--smoke=<s>` | log a line and quit after s seconds (implies `--hidden` on Windows) |

`STRISO_LIVE_HOME` moves the data folder (tests, smoke runs).

## Build

Flutter 3.41 (Dart 3.11), Visual Studio 2022 with the C++ desktop workload on Windows, Xcode on
macOS.

```
cd tools/striso_live
flutter test                                 # widget and controller tests (headless)
(cd packages/striso_core && dart test)       # protocol, parser, client, harmony, params, touch, config
flutter build windows --release              # build\windows\x64\runner\Release\StrisoLive.exe
powershell -File tool\package_windows.ps1    # dist\StrisoLive-1.1.0-windows-x64.zip

flutter build macos --release
tool/bundle_libusb_macos.sh "build/macos/Build/Products/Release/Striso Live.app"   # needs brew's libusb
```

`.github/workflows/striso-live-flutter.yml` runs the tests and builds both platforms on
windows-latest and macos-latest (a universal libusb for macOS, the Windows zip and installer) and
uploads them as artifacts.

Headless USB check (no window; read-only: V, v, p, f, S, s):

```
cd packages/striso_usb
dart run bin/striso_probe.dart --lib path\to\libusb-1.0.dll probe
dart run bin/striso_probe.dart --lib path\to\libusb-1.0.dll connect 1
```

## Layout

- `packages/striso_core`: pure Dart, no Flutter: protocol and stream parser, client (request
  queue, coalesced parameter writes, stream watchdog), demo board, key layout, live key state,
  harmony analysis, parameters/presets/undo/morph/C export, key equalizer math, settings-mode
  map, config UF2 writer and the save flow. `dart test`: ports of the web app's tests, the config
  writer compared byte for byte with `tools/striso.py`, the settings map against the firmware
  source when it is checked out.
- `packages/striso_usb`: libusb-1.0 through `dart:ffi` (own thin bindings: no maintained package
  fits), the I/O in a background isolate with 16 bulk IN transfers in flight; the UI never waits
  on USB.
- `lib/`: the app (controller, panels, painters).
- `assets/fonts/Inter.ttf`: Inter (variable), SIL Open Font License 1.1 (`assets/fonts/OFL.txt`),
  bundled so the type is the same on Windows and macOS. Design tokens and components:
  `lib/src/theme.dart`, from `DESIGN.md`.
- `windows/libusb/libusb-1.0.dll`: libusb 1.0.30 x64 (LGPL-2.1, see `LIBUSB-NOTICE.txt`),
  installed next to the exe by `windows/CMakeLists.txt`.
