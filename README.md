# Striso Live (desktop)

The live companion for the Striso board as a Flutter desktop app for Windows and macOS.

## Install

**macOS** (Apple silicon and Intel), in Terminal:

```
curl -fsSL https://raw.githubusercontent.com/aidin-foroughi/striso-live/main/install-mac.sh | bash
```

**Windows** (x64), in PowerShell:

```
irm https://raw.githubusercontent.com/aidin-foroughi/striso-live/main/install-windows.ps1 | iex
```

Both download the latest release, check its SHA-256, close a running copy, install (macOS:
`/Applications`, or `~/Applications` when that needs sudo; Windows:
`%LOCALAPPDATA%\Programs\Striso Live` with a Start menu shortcut, no admin) and start the app. Run
them again to update.

Or download by hand from the [Releases page](https://github.com/aidin-foroughi/striso-live/releases/latest):
`StrisoLive-<version>-macos.dmg` (open it, drag Striso Live to Applications),
`StrisoLive-<version>-macos.zip`, `StrisoLive-<version>-windows-setup.exe` (per-user installer) or
`StrisoLive-<version>-windows-x64.zip` (portable). `SHA256SUMS.txt` has the checksums.

**The builds are not signed.** On macOS the app is signed ad hoc only, so a downloaded copy is
refused on the first double-click: right-click it, choose **Open**, then **Open** again, or run
`xattr -dr com.apple.quarantine "/Applications/Striso Live.app"` (the install script does this).
On Windows SmartScreen may say *Windows protected your PC*: click **More info**, then **Run
anyway**.

The firmware, its build and flash tools are in
[striso-control-firmware](https://github.com/aidin-foroughi/striso-control-firmware) (`tools/`).

It shows the playing on the real key layout (pressure, tilt, strikes, motion), browses voices and
presets, edits the live parameters (voice and effects) with undo, mutate and a morph pad, keeps
your own sounds, names chords with roman numerals and a progression strip, highlights scales,
shows what every key does in the Striso's settings mode, and evens out the keys (touch settings,
key equalizer with a live pressure meter and Suggest) and saves those to the board.

USB goes through libusb-1.0 directly (no browser, no WebUSB device chooser): on this PC the app
is live about 0.3 s after it starts talking to the board.

## Run it

### Windows

1. Unzip `StrisoLive-<version>-windows-x64.zip` anywhere and run `Striso Live\StrisoLive.exe`.
2. The build is not signed, so SmartScreen may say *Windows protected your PC*: click
   **More info**, then **Run anyway**. Windows remembers it for this file.
3. Plug in the Striso and click **Connect Striso**, or **Play Virtual Striso** without one.

The installer (`StrisoLive-<version>-windows-setup.exe`) installs per user without admin rights
and gets the same SmartScreen warning.

The Striso's USB interface 2 must use the WinUSB driver (the board asks for it itself; if
Connect says there is no usable driver, the Zadig tool can set WinUSB for *Striso, interface 2*).

### macOS

1. Open `StrisoLive-<version>-macos.dmg` and drag **Striso Live** to Applications (or unzip
   `StrisoLive-<version>-macos.zip` and move **Striso Live.app** there).
2. The app is signed ad hoc only, so Gatekeeper refuses a double-click the first time:
   right-click the app, choose **Open**, then **Open** again. Or in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Striso Live.app"`.
3. libusb is inside the app (`Contents/Frameworks/libusb-1.0.0.dylib`), and the audio engine
   (`libstriso_audio.dylib`). The app is not sandboxed: it needs USB and it writes the settings to
   the Striso's update drive in /Volumes.
4. The first time Through PC or Record opens the Striso's input, macOS asks whether Striso Live
   may use audio input (the input counts as a microphone). If you said no: System Settings ›
   Privacy & Security › Microphone, Striso Live on. The ad hoc signature changes with every
   update, so macOS may ask again after one.

### Good to know

- **One program at a time.** Only one program can hold the Striso's interface. If Connect says
  the board is busy, close the web app tab, the Electron app or a `tools/striso.py` session
  (the firmware repository's board tool).
- **Reconnects by itself** after an unplug or a reboot, 4 s after the board is back (so a flash
  tool gets it first), retrying a busy board for 30 s; never after you clicked Disconnect.
  At start it connects right away when you left it connected.
- **Your data** lives in `%APPDATA%\Striso Live` (Windows) or
  `~/Library/Application Support/Striso Live` (macOS): `settings.json` (preferences, your sounds,
  morph corners), `logs/striso-live.log` (also in the console drawer) and `backups/` (the board's
  previous settings, saved before every Save to Striso).
- **Errors** never open a native dialog: they go to the console drawer and the log file.

### Through PC and Record

Firmware with USB audio (the board shows up as the input **Striso Synth**: UAC1, 48 kHz stereo,
24 bit) plays its synth through the computer's speakers or interface, no DAW needed. The
headphone jack keeps working at the same time.

- **Through PC** (header, Striso mode only; off until you turn it on, then remembered): while the Striso is connected, its USB audio plays through the computer. Without a Striso session nothing is opened, whatever the toggle says. The
  Striso's input plays to the default output, or the one chosen in Setup › Audio. The pip next to
  the toggle is the input level (red at full scale, red when the input is gone, accent while it
  looks); a click opens Setup.
- **Setup › Audio**: input (automatic finds the Striso by its USB IDs VID 0xF055 / PID 0x57C0, else
  by a name with "Striso" in it, never by a stored endpoint id; or pick any input), output, buffer,
  the latency, dropouts, gain (−40 to +6 dB, −6 dB at first), the input meter and the status. On
  Windows: **Exclusive input** (on: the Striso's own 24-bit samples at the device's shortest period;
  off: shared, 10 ms) and **Exclusive output** (on by default for wired outputs: the lowest latency,
  nothing else plays to that output meanwhile; shared with a quiet note when another program holds
  it; Bluetooth outputs always shared; off: always shared). macOS has no exclusive mode.
- **Buffer: Auto (recommended)** or 64 / 128 / 256 / 512 frames per period. Auto starts at 256 on an
  output it does not know, tries a step smaller after 20 s without a dropout (at a quiet moment:
  a change reopens the devices), steps back at the first output-side dropout, and remembers per
  output (its WASAPI endpoint id or Core Audio UID, and the share mode) what played cleanly and
  what did not. It never asks for less than the device's minimum period (Windows reports it; on
  the development PC every USB device's minimum is 3 ms, 144 frames).
- **Latency**: the total through the computer and, under it, its parts: input (half the input's
  wake-up interval and the stream latency the system reports), ring (the passthrough's ring and
  resampler), output (its buffer and the reported stream latency; Core Audio: device + stream
  latency + safety offset), USB (the board's ring before each packet, as it reports it).
- **Dropouts**: how many in the last minute, and where: the board (its ring ran dry, a frame the
  host skipped, a packet not ready: its own counters, console `StcU`, read every 2 s), the input
  (late, or the ring full), the output (late beyond what its buffer bridges, or the ring empty).
  Every dropout is in the console and the log with its time and cause; once a minute the log has
  the callback timing of both devices.
- **Striso buffer** (firmware with `Stct`): the board's own buffer before USB: Auto (the smallest
  that keeps the board at 0 underruns, from 96 frames) or 72 / 96 / 120 / 144. The app sets it on
  every connection.
- A Bluetooth output gets one line: "Bluetooth adds ~150–250 ms. Use a wired output for playing."
- **Record** (Setup › Audio): the Striso's input to a WAV file, 48 kHz stereo, 24 bit when the
  Striso sends 24 (else 16, or 32-bit float), in `Documents\Striso Live Recordings` with a
  timestamped name (`Striso 2026-10-23 14.02.11.wav`). The header shows the time while it records
  (a click stops); Show in folder when it is done. It records with Through PC off too.
- A board that restarts (a firmware update, Save to Striso) or is replugged comes back by itself;
  a recording ends with a note when the input goes away. Firmware without USB audio: Setup says
  so.
- The audio runs in a small native library (`striso_audio`: miniaudio on WASAPI / Core Audio) on
  its own threads; the app only sets it up and reads levels, counters and the event log (no lock
  the audio callbacks take, no allocation in them). Drift between the Striso's clock and the
  output's is corrected continuously (a resampler steered by the buffer's fill: a few ppm,
  inaudible), so it never clicks or drifts away. The ring's target follows what the devices do:
  the longest wait for the input and the output's biggest take over the last half minute
  (measured in bursts, not callbacks), plus a margin that grows at an underrun and shrinks after
  stable playing.
- Real time on Windows: the device threads are TIME_CRITICAL and in MMCSS "Pro Audio" at
  AVRT_PRIORITY_CRITICAL, exclusive streams are event driven, `timeBeginPeriod(1)` is held while a
  device is open and the process opts out of power throttling. On macOS Core Audio's own
  real-time IO thread runs the callbacks.

**Volume.** The Striso's synth is a full-level signal; Through PC starts at −6 dB, but turn the
computer down before the first try.

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
  labels; the chord, roman numeral, progression and key; the hero knobs of the voice and the
  effect amounts, as the firmware names them for the voice it plays (StcH; a name the board does
  not list shows as an error).
- **Sound**: every voice and effect parameter, undo/redo, Reset, Mutate, A/B, Save sound, Copy as
  C; My sounds; the morph pad (closed until you open it).
- **Setup**: Sensitivity, Key equalizer or Settings keys on the big board; Save to Striso;
  Audio (Through PC, devices, Record); motion; firmware.
- **Stage mode** (F or F11, Esc leaves): only the board and the chord, larger.
- After a reconnect, if the board lost your edits (a restart, Save to Striso), a toast offers to
  restore the edited sound.

### Keys

`1`-`8` engines, `[` `]` previous/next preset, `Ctrl+1/2/3` tabs, `Ctrl+Z`/`Ctrl+Y` undo/redo,
`Ctrl+S` save the sound, `M` mutate, `B` (hold) A/B, `F`/`F11` stage, `` ` `` console, `S`
settings keys, `?` all of these. Knobs: drag (Shift: fine), scroll, arrow keys; double-click
resets; Alt+click locks against Mutate.

### Command line

| flag | |
|---|---|
| `--demo` | start in Virtual mode |
| `--virtual-lib=<path>` | the firmware build Virtual runs: a `striso_virtual.dll` / `.dylib` / `.so` built from any firmware branch (default: the one chosen in Setup, `$STRISO_VIRTUAL_LIB`, the newest in the firmware folder, or `../striso-control-firmware/build/host-virtual/virtual/`) |
| `--mock-demo` | Virtual on the Dart mock board instead (no native library) |
| `--no-usb` | never touch USB |
| `--fake-save[=fail]` | Save to Striso runs every step except the drive (works in the demo) |
| `--hidden` | the window stays out of sight (Windows: minimized and off-screen; macOS: invisible, no Dock icon) |
| `--smoke=<s>` | log a line and quit after s seconds (implies `--hidden`) |
| `--no-audio` | no Through PC or Record (the audio library is not loaded) |

`STRISO_LIVE_HOME` moves the data folder (tests, smoke runs).

## Build

Flutter 3.41.2 (Dart 3.11), Visual Studio 2022 with the C++ desktop workload on Windows, Xcode on
macOS. From the repository root:

```
flutter pub get
flutter test                                 # widget and controller tests (headless)
(cd packages/striso_core && dart test)       # protocol, parser, client, harmony, params, touch, config
flutter analyze
flutter build windows --release              # build\windows\x64\runner\Release\StrisoLive.exe
powershell -File tool\package_windows.ps1    # dist\StrisoLive-<version>-windows-x64.zip
iscc /DAppVersion=<version> tool\installer.iss   # dist\StrisoLive-<version>-windows-setup.exe (Inno Setup 6)

flutter build macos --release                # universal (arm64 + x86_64)
sh tool/package_macos.sh [libusb-1.0.0.dylib]   # libusb into the app, dist/*.zip and *.dmg; default: brew's libusb
```

`flutter build windows` also builds the audio engine (`packages/striso_audio/native`, through
`windows/CMakeLists.txt`) and puts `striso_audio.dll` next to the exe. On macOS
`tool/package_macos.sh` builds `libstriso_audio.dylib` universal into the bundle; for `flutter run`
on macOS build it once with `sh packages/striso_audio/native/build_macos.sh` and point
`STRISO_AUDIO_LIB` at `packages/striso_audio/native/build/macos/libstriso_audio.dylib`.

Audio engine checks (none of them plays a sound):

```
cmake -S packages/striso_audio/native -B build/striso_audio     # Windows (macOS: sh packages/striso_audio/native/build_macos.sh --selftest)
cmake --build build/striso_audio --config Release
build\striso_audio\Release\striso_audio_check --selftest <scratch dir>   # passthrough, drift servo, resampler, bursts and late callbacks, the buffer sweep, WAV writer, null-backend sessions
build\striso_audio\Release\striso_audio_check --list                     # the devices: the Striso marked, transport, device periods, ids (opens no stream)
build\striso_audio\Release\striso_audio_check --capture 3 take.wav       # the Striso's input only, at most 5 s: format and level
(cd packages/striso_audio && dart test)                                   # state machine; the dart:ffi binding on the null backend
(cd packages/striso_audio && dart run bin/audio_check.dart record 3)      # the same through the app's Dart engine
```

Run it from the build: `build\windows\x64\runner\Release\StrisoLive.exe` (Windows) or
`open "build/macos/Build/Products/Release/Striso Live.app"`; `--demo --no-usb` without a board.

**Firmware cross-checks.** Some `striso_core` tests compare with the firmware source: the config
writer byte for byte with the firmware's `tools/striso.py` (through its `tools/.venv`, see
`tools/requirements.txt` there). They look for a
[striso-control-firmware](https://github.com/aidin-foroughi/striso-control-firmware) checkout in
`$STRISO_FW_DIR`, else in `../striso-control-firmware` next to this repository, and skip with a
message when there is none. Both firmware layouts work: the flat one (`voice_*.h`, `fx.h`,
`synth_control.cpp` at the root) and the split one (`dsp/include/striso_dsp/`, `src/synth/`).
An engine newer than the checkout (the trumpet before its merge) is skipped with a message; its
voice key may be missing from the checkout's `synth_control.cpp`. `STRISO_PYTHON` overrides the
Python for the config test.

**CI.** `.github/workflows/striso-live-flutter.yml` runs the tests (with the audio engine's native
self-test and package tests) and builds both platforms on
windows-latest and macos-latest (with a universal libusb for macOS) for every push to main and
every pull request, and uploads the zips and the dmg as workflow artifacts. It clones the firmware
next to the app so the cross-checks run.

**Releases.** Set the version in `pubspec.yaml`, commit, then push a matching tag:
`git tag v1.1.0 && git push origin v1.1.0`. `.github/workflows/release.yml` tests, builds the
Windows zip and installer and the universal macOS dmg and zip, and publishes a GitHub Release with
them, fixed-name copies for the install scripts (`StrisoLive-macos.zip`,
`StrisoLive-windows-x64.zip`, each with a `.sha256`), `SHA256SUMS.txt` and generated notes. Run by
hand (Actions, Release, Run workflow) it only builds, as workflow artifacts.

Headless USB check (no window; read-only: V, v, p, f, S, s):

```
cd packages/striso_usb
dart run bin/striso_probe.dart --lib path\to\libusb-1.0.dll probe
dart run bin/striso_probe.dart --lib path\to\libusb-1.0.dll connect 1
```

## Testing without the hardware

**Two modes.** **Striso**: the app manages and plays the hardware over its USB console (voices, parameters, settings, tunings, Save to Striso, Through PC). **Virtual**: a standalone soft instrument, the Striso firmware compiled for the computer (the firmware repository's `virtual/`, built as the `striso_virtual` library by `tools/virtual.sh`): the same `synth_control.cpp`, every voice engine and the effects, the console protocol and the config store. It holds no USB session with any Striso. The header's **Striso | Virtual** control switches; a switch is a full teardown of one mode, the same as Disconnect, then the start of the other. The architecture is in `docs/architecture.md`.

In Virtual the app talks to the firmware over the same console protocol as to the Striso (`packages/striso_virtual`: `VirtualBoardTransport`), so the lists, voices, live parameters, A/B, touch and key settings, the settings overlay and tunings all act on the virtual instrument. Save writes through its own bootloader drive into its flash, which is kept on this computer (`<data>/virtual/flash.bin`) and boots the next one.
- **Sound**: Virtual plays to the computer's output (Setup › Audio: the output, its buffer (Auto), exclusive mode and gain), whatever Through PC says: it renders inside the output's callback (`sa_set_source` with `sv_audio_source`). Its clock never depends on the output. When the output does not open or stalls, it runs on its own real-time thread, and the status says "No sound: …".
- **Input**: any MIDI or MPE controller the computer sees (the Striso through its USB MIDI port, a LinnStrument, a keyboard), chosen in the header's **Input** menu, and the on-screen board. The bytes go from the MIDI driver's thread (WinMM, CoreMIDI; `striso_audio`'s MIDI inputs) straight into the firmware's own USB-MIDI input (`sv_midi_write`) with no Dart on the path. The app maps nothing: the firmware's MIDI input handles them. The first time Virtual plays, every input there is chosen. Hot-plug: a chosen input that comes back is opened again.
- **MIDI 2.0**: a MIDI 2.0 controller's Universal MIDI Packets go, whole and untouched, into the firmware's MIDI 2.0 input (`sv_ump_write`) at their full resolution; the Input menu marks such inputs **MIDI 2.0**. Windows: through Windows MIDI Services, the MIDI 2.0 service in recent Windows 11 (`midisrv`), with its SDK's `Windows.Devices.Midi2.dll` next to the exe (`packages/striso_audio/native/third_party/midi2`); without the service there is no MIDI 2.0 and MIDI 1.0 goes through WinMM. macOS 11+: CoreMIDI's MIDI 2.0 protocol for sources that declare it.
- **Firmware**: the app ships none. Setup › Virtual firmware lists the builds in the firmware folder (`%APPDATA%\Striso Live\firmware\<version>\striso_virtual.dll`, `~/Library/Application Support/Striso Live/firmware/<version>/libstriso_virtual.dylib`). **Load…** takes one from anywhere. A switch unloads the old library and starts Virtual on the new one without a restart. A library with another C API (`sv_api_version`) is refused with a clear message.

**The firmware is the source of truth.** The app shows what the board (real or virtual) reports and reads it again whenever the board's change counter moves (`Stcy`, every 250 ms while connected): the voice, every value, the tuning, the transposition. The settings overlay is the board's own list (`StcX`). A Striso without these commands gets one message: "This Striso needs a firmware update to work with Striso Live (found …)".

**Disconnect** ends the whole session: the console, the stream, every poller, Through PC's devices, the virtual instrument, its output and the MIDI inputs. Nothing runs until Connect (or Play Virtual Striso) again, as the user left it. The status line says what plays and where, e.g. "Virtual Striso (a647e81) → Headphones · input: LinnStrument".

Latency, MIDI key to sound (estimates, not measured): the controller's USB frame (up to 1 ms), the MIDI driver (WinMM about 1–2 ms with a few ms of jitter on the legacy stack; CoreMIDI about 0.5–1 ms), the firmware's MIDI input in its next 32-frame block, the wait for the next output callback (up to one buffer) and the output itself (WASAPI exclusive at 3 ms: about two buffers): roughly 7–12 ms on Windows exclusive, 6–10 ms on Core Audio at a small buffer. A Striso as the controller sends 7-bit channel pressure and CC74 tilt, and 14-bit pitch bend that carries its tuning and the sideways tilt. The native key stream it uses over its console has 14 bits for all of them.

Tests: `cd packages/striso_virtual && dart test` (the client on the virtual board, save, reset and reconnect, real audio, an engine-level render equal to its golden, loading and unloading libraries) and `flutter test test/virtual_board_test.dart` (the controller on it: as the USB Striso, as Virtual, its sound on the null output with Through PC off, a dead output, MIDI bytes reaching the firmware, a firmware switch, the board changed behind the app's back). They find the library through `$STRISO_VIRTUAL_LIB`, `$STRISO_FW_DIR` or `../striso-control-firmware` and skip without it; the sound tests also need `$STRISO_AUDIO_LIB` (a striso_audio build). `test/disconnect_test.dart` checks with fake time that Disconnect leaves no transport, device, MIDI input or timer. CI: `.github/workflows/virtual-board.yml` takes the library from the firmware's release (`striso_virtual-<tag>-windows-x64.zip`, `striso_virtual-<tag>-macos-universal.zip`; the repository variable `FIRMWARE_TAG`, else the latest release), checks it against the release's `SHA256SUMS` and its C API version against `packages/striso_virtual`, and runs both on Windows and macOS. The app does not ship the virtual board: it is a firmware artifact, loaded at run time.

## Testing without the UI

Latency, dropouts and Through PC are measured electronically by `packages/striso_bench`, a
command-line tool that runs the app's own audio engine (`striso_audio` through dart:ffi) and its
own Through PC code (`ThroughPc`, `BoardAudioLink`), plus the board's console. It prints a JSON
report (schema `striso-bench/1`, `lib/src/report.dart`) and exits 0 when every check passed.
**Nothing makes a sound.** A real output is only opened to play digital silence, at most 30 s per
run. The engine's silence guard forces every output sample to 0 and counts any that was not; a
run fails if one was. Exclusive output is never taken from a program that is playing to that
output. On a hardware run the bench closes a running Striso Live, which holds the board's console.

How it measures:

- **The marker.** Firmware with `Stcl` (console `Stcl1`) writes a 32-frame pseudo-random burst at
  −20 dBFS over the right channel of its next USB packet (USB only; the jack never has it). It
  replies with the packet's frame number, its ring level and the time from the command's OUT
  packet to the marker's IN transfer (the board's own clock). `Stcl0` is an echo that says how long
  the board held it, so the console's round trip splits into transit.
- **The host's clocks.** The USB worker stamps every transfer on the process's monotonic clock
  (QueryPerformanceCounter). The audio callbacks record timing marks, and the taps carry the input
  as it arrives and the output before its gain (`sa_probe`). The output's own clock
  (`IAudioClock`, or Core Audio's presentation time) says when an output frame plays.
- So the marker's packet on the bus is known on the host clock: sent + console one-way + the
  board's time. Correlation then finds it in the input, and again in the output after the
  resampler, even at gain 0. Every number in the report says whether it was **measured**,
  **reported** (a ring level, a stream latency) or **estimated**.

One line each (from `packages/striso_bench`; `--sim` runs any of them without hardware, on
miniaudio's null backend and a simulated board, with deterministic usb-in numbers):

```
dart run bin/striso_bench.dart usb-in                # bus -> capture callback, exclusive and shared, 50 markers each
dart run bin/striso_bench.dart out                   # the output alone, silence: its latency by its own clock, exclusive/shared x 128/256/Auto
dart run bin/striso_bench.dart through --seconds 25  # Through PC at gain 0: end to end and its parts, dropouts by side, Auto, CPU
dart run bin/striso_bench.dart soak --minutes 5      # the same for dropouts
dart run bin/striso_bench.dart targets --targets 72,80,96 --seconds 20   # board ring targets: board underruns
dart run bin/striso_bench.dart stats                 # StcU, the drivers bound to the USB functions (usbaudio2, WinUSB), the MIDI port
dart run bin/striso_bench.dart all --json out.json   # all of the above
```

Through PC runs with the settings in Striso Live's `settings.json` (read, never written).
`--excl-in on|off`, `--excl-out on|off` and `--period N|auto` override them.

Tests:

```
(cd packages/striso_bench && dart test)              # marker detection, timestamp alignment, statistics, the report schema, the simulated run
(cd packages/striso_bench && dart test -t hardware)  # with a Striso: connect < 1 s, usbaudio2 + MIDI, usb-in median < 8 ms, no board underruns, silence
powershell -File tools\hwtest.ps1                    # the whole hardware suite: test-results\hw-<time>.json, .txt, .log
sh tools/hwtest.sh                                   # the same on macOS
```

`test-results/` is gitignored. CI (`.github/workflows/striso-live-flutter.yml`) runs the bench
tests and a simulated `all` on Windows and macOS. Measured on the development PC (TBT200 dock,
UAC2 firmware, exclusive in and out at the device minimum, 144 frames): usb-in 2.5 ms median;
Through PC end to end 13.9 ms median (board 2.4, usb-in 2.5, ring 4.3, output 4.6), 0 dropouts
over 3 minutes.

## Layout

- `packages/striso_core`: pure Dart, no Flutter: protocol and stream parser, client (request
  queue, coalesced parameter writes, stream watchdog), demo board, key layout, live key state,
  harmony analysis, parameters/presets/undo/morph/C export, key equalizer math, settings-mode
  map, config UF2 writer and the save flow. `dart test`: ports of the web app's tests, the config
  writer compared byte for byte with the firmware's `tools/striso.py`, the settings map against
  the firmware source when it is checked out (see Firmware cross-checks).
- `packages/striso_audio`: Through PC and Record. `native/`: the C library (miniaudio 0.11.25 with one local patch,
  vendored with its licence in `native/third_party/miniaudio`; the passthrough with its drift servo
  and resampler, the WAV writer, the self-test; `build_macos.sh`, `CMakeLists.txt`), `lib/`: its
  `dart:ffi` binding and the Through PC state machine (`ThroughPc`), with a fake backend for tests.
  miniaudio rather than a Dart package: no maintained Dart package does low-latency duplex
  capture to playback on both WASAPI and Core Audio, and none keeps the audio off the Dart thread.
- `packages/striso_usb`: libusb-1.0 through `dart:ffi` (own thin bindings: no maintained package
  fits), the I/O in a background isolate with 16 bulk IN transfers in flight; the UI never waits
  on USB.
- `lib/`: the app (controller, panels, painters). Several files are ports of the earlier web app
  (`tools/app` in the Striso tooling repository), which their header comments name.
- `tool/`: packaging (`package_windows.ps1`, `installer.iss`, `package_macos.sh`,
  `bundle_libusb_macos.sh`) and the icon generator; `install-mac.sh`, `install-windows.ps1`: the
  one-line installers.
- `assets/fonts/Inter.ttf`: Inter (variable), SIL Open Font License 1.1 (`assets/fonts/OFL.txt`),
  bundled so the type is the same on Windows and macOS. Design tokens and components:
  `lib/src/theme.dart`, from `DESIGN.md`.
- `windows/libusb/libusb-1.0.dll`: libusb 1.0.30 x64 (LGPL-2.1, see `LIBUSB-NOTICE.txt`),
  installed next to the exe by `windows/CMakeLists.txt`.
