# Striso Live: connecting, Virtual and firmware builds

The flows for what plays, how it starts and stops, and how a new sound is tried. The visual
language is `DESIGN.md`; the session mechanics are `docs/architecture.md`. This document decides
what the user sees and clicks.

## 1. What made no sense (the audit, October 2026)

Read from the code and the log of the installed build, state by state.

- **Two vocabularies for one thing.** The header had a `Striso | Virtual` control *and* a
  `Connect / Disconnect` button; the start screen had `Connect Striso` and `Play Virtual Striso`.
  Four controls, two verbs ("connect", "play"), one action: start an instrument. After Disconnect
  the segmented control showed nothing selected. In Virtual the button said *Disconnect*, but
  nothing had been connected.
- **The first launch asked for a click it did not need.** With the Striso plugged in, the app sat
  on "Plug in your Striso" (it was plugged in) until Connect was clicked, because a never-chosen
  intent was treated as "do not connect". Replugging later did connect by itself. Two rules for
  one cable.
- **Through PC had no home.** A bare toggle in the header in Striso mode; the same slot showed
  the MIDI input in Virtual; Setup › Audio hid the toggle in Virtual but kept the preference. So
  the question "what does Through PC mean in Virtual?" had no answer on screen: it means nothing
  there, and the screen never said so.
- **Firmware builds were folder names at the bottom of Setup.** To try the new sax: Setup, scroll
  past Save, Audio, Motion and Firmware to "Virtual firmware", open a select of names like
  `2026-10-24_audition sax v1 (56f7266)` and `2026-10-25_v2.2.4-308-g3e05282_all`, pick one, go
  back to Play, find the engine. To compare with the current sound: the same trip back. Nothing
  said which build was the one on the board, which were auditions, or what an audition contained.
- **Picking a build did different things in different modes.** In Virtual it restarted Virtual on
  the build. In Striso mode it swapped the library silently and toasted a version: nothing
  audible changed. "I picked the sax and nothing happened."
- **A build that could not load was offered, then failed with a path.** The audition DLLs built
  against C API 1 sat in the picker like the others; choosing one produced the banner *"That
  firmware build cannot run here: Bad state: C:\Users\…\striso_virtual.dll: its C API is version
  1, this app speaks version 2: use a firmware build for this app"*. No name, no fix, and the
  select kept showing the broken build as chosen while nothing ran. The library getter then
  retried the load on every read of the picker.
- **Errors were sentences, not states.** Busy, no driver, no Striso, too old, no library: each a
  banner of prose; none offered the action that fixes it (connect again, pick another build,
  install one, open the folder, clear the quarantine, get the runtime).
- **Small lies.** "Save to Striso" in Virtual (it saves to the virtual board's flash); the stage
  strip said "Not connected" while Virtual played; the status line in Virtual named a commit
  (`a647e81`), not the sound.

## 2. The mental model

**One instrument plays at a time: your Striso, or Virtual.** The Striso is the board over USB; it
makes its own sound and the app shows and sets it. Virtual is the Striso firmware running on this
computer, played from MIDI controllers (your Striso among them, through its USB MIDI port) and the
on-screen board. The header names what plays in one place, and that same control switches.

**Virtual runs a firmware build. The user picks a sound to try; the build is how it gets here.**
Auditions arrive as builds; the app lists them by their title where the engines are, in Play,
and switching builds keeps you on the same key so the comparison is one click.

**The Striso connects by itself** when it is on USB, unless you told the app to let go of it.
Nothing else connects, plays or opens a device without a click.

**A problem is a state with a fix.** Every way the session can fail has a title, a sentence and
the button that fixes it, in the banner under the header and on the board.

## 3. The header

The left control is the instrument. The right end is the status (one line: what plays and where)
and the one button that ends it. Nothing else about the session is in the header.

```
Striso plays
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◉ Striso Live  [Striso][Virtual]      Play  Sound  Setup   ▁▂▃ 12%  Through PC ⬭ ·  ● Striso · Through PC → Headphones  [Disconnect] │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
Virtual plays
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◉ Striso Live  [Striso][Virtual]      Play  Sound  Setup   ▁▂▃  4%  Input: Striso ▾  ● Virtual · Sax v1 → Headphones     [Stop]  │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
Nothing plays
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◉ Striso Live  [Striso][Virtual]      Play  Sound  Setup                                  ○ Not connected                │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `[Striso][Virtual]`: ghost segments; the one that plays is filled (bg3). A click on the other
  ends this instrument completely and starts that one. While nothing plays neither is filled, and
  a click starts that instrument. The Striso segment's tooltip says whether a Striso is on USB.
- The trailing button exists only when there is something to end: **Disconnect** (Striso: let go
  of the board; it stays away until you click Striso again), **Stop** (Virtual), **Cancel** (a
  connect is waiting). Otherwise there is no button: the segments are the actions.
- The status line, by state (dot colours per DESIGN.md 4.6; Virtual's dot is the demo blue):

| state | dot | line |
|---|---|---|
| nothing, no Striso on USB | hollow | Not connected |
| Striso found, connect due | accent, pulsing | Striso found · connecting in 4 s |
| connecting | accent, pulsing | Connecting… / Starting Virtual… |
| Striso plays | ok | Striso · heard from its jack / Striso · Through PC → Headphones |
| Virtual plays | demo | Virtual · Sax v1 → Headphones · input: Striso |
| Virtual, output failed | demo | Virtual · Sax v1 · No sound: the output would not open |
| saving / virtual restart | accent, pulsing | Saving to the Striso… / Virtual restarts… |
| disconnected by you | hollow | Disconnected |
| Virtual stopped by you | hollow | Stopped |
| unplugged | error | Unplugged |
| busy | accent | Striso busy |
| a problem (section 7) | error | its title |

The tooltip of the status keeps the firmware version, the running resources and the stream
numbers; a click opens the console.

**Through PC** is a Striso thing ("hear the Striso on this computer; its jack keeps working") and
lives in the header only while the Striso plays, with its level pip. In Virtual the slot shows the
**Input** menu (which MIDI inputs play Virtual; the on-screen board always does). Setup › Audio
says in one line what plays to the output in the current state and shows the Through PC toggle
only for the Striso.

## 4. Starting

The board area carries the start screen: the board at 45%, no card, a title, one sentence, the
actions (DESIGN.md 4.6). It changes with the state.

```
first launch, nothing on USB                     first launch, Striso on USB
┌──────────────────────────────┐                 ┌──────────────────────────────┐
│                              │                 │                              │
│     Plug in your Striso      │                 │     Striso found             │
│  It connects by itself. Or   │                 │  Connecting…                 │
│  play Virtual: the Striso    │                 │                              │
│  firmware on this computer.  │                 │                              │
│        [Play Virtual]        │                 │                              │
└──────────────────────────────┘                 └──────────────────────────────┘

plugged in later (4 s for a flash tool)          after Disconnect
┌──────────────────────────────┐                 ┌──────────────────────────────┐
│     Striso found             │                 │     Disconnected             │
│  Connecting in 4 s…          │                 │  You let go of the Striso.   │
│  [Connect now] [Play Virtual]│                 │  [Connect Striso] [Play Virtual]│
└──────────────────────────────┘                 └──────────────────────────────┘

unplugged                                        Virtual stopped
┌──────────────────────────────┐                 ┌──────────────────────────────┐
│     Striso unplugged         │                 │     Stopped                  │
│  It reconnects by itself a   │                 │  Nothing plays.              │
│  few seconds after it is back│                 │  [Connect Striso] [Play Virtual]│
│        [Play Virtual]        │                 └──────────────────────────────┘
└──────────────────────────────┘
```

Step by step:

1. **First launch.** Striso on USB: it connects (about 0.3 s), the board lights up, done. Nothing
   on USB: "Plug in your Striso" with `Play Virtual` as the only button. The presence poll runs.
2. **Plugged in later**: "Striso found · connecting in 4 s" (a flash tool gets the board first);
   `Connect now` skips the wait, `Cancel` in the header stops it. A busy board is retried quietly
   for 30 s, then becomes the *busy* problem (section 7).
3. **Disconnect** (header): the console, the stream, Through PC's devices and every poller end.
   The Striso stays away, through restarts of the app, until you click `Striso` or
   `Connect Striso`. The presence poll is off: nothing watches USB.
4. **Striso → Virtual** (header segment, or `Play Virtual`): the Striso session ends as in 3 (but
   it does not count as a Disconnect), Virtual starts on the last build played, its output
   opens, the chosen MIDI inputs open. The Striso's own synth keeps playing through its jack; as
   a MIDI input it plays Virtual.
5. **Virtual → Striso**: Virtual stops (output and MIDI closed, the board destroyed, its config
   flash kept), the Striso connects.
6. **Stop** (header, Virtual): Virtual ends; nothing plays. The Striso is not grabbed, but a
   Striso plugged in from now on connects by itself as in 2.
7. **Unplug** while the Striso plays: Through PC closes at once, the status says Unplugged, the
   start screen says it reconnects by itself. **Replug**: as in 2. The edited sound comes back
   with its toast when the board lost it (DESIGN.md 6.3). Unplugging the Striso while Virtual
   plays only drops it as a MIDI input; it is reopened when it is back.
8. **Next launch** resumes what was playing: Virtual if Virtual was on, else the Striso if it is
   on USB and you did not disconnect it.

## 5. Virtual: builds as sounds to try

In Virtual the Play tab's left column starts with the build. The engine row below it is the
build's: an audition puts the new engine on a voice key (the sax on key 26, where the wind engine
normally sits; the wind engine moves to key 16 so both are in the row).

```
┌ Play, Virtual ────────────────────────────────────────┐
│ VIRTUAL                                               │
│ Sax v1                                        ▾   ⇄   │   the build; ⇄ back to the build played before
│ Soprano, alto, tenor, baritone on the wind key        │   its description, when it has one
│                                                       │
│ ○ ● ○ ○ ○ ○ ○ ○                                       │   the engine row of this build
│ Sax                                                   │
│ saxophone                                             │
│ soprano                                               │
│ ● alto                                                │
│ tenor                                                 │
│ baritone                                              │
│ MY SOUNDS                                             │
│ …                                                     │
└───────────────────────────────────────────────────────┘

the build menu
┌─────────────────────────────────────────────────────────────┐
│ BUILDS                                                      │
│ ● Sax v1                              56f7266              │
│   Trumpet stage 2-3                   409b011              │
│   Flute v1                            bee9528              │
│   Double reed v1                      58e702f              │
│   Clarinet v1                         7cd0c3a              │
│   Accordion v3                        a6b2b05              │
│   v2.2.4-308                          3e05282 · on your Striso │
│   2026-10-24_audition trumpet (20a9151)   built for another Striso Live (API 1)   ← greyed │
│ ─────────────────────────────────────────────────────────── │
│   Install a release zip…                                    │
│   Open the firmware folder                                  │
└─────────────────────────────────────────────────────────────┘
```

- **A build is named by its `manifest.json` (`title`), else by its folder name.** Release zips
  installed through the app carry a manifest; audition folders need one (section 8). The second
  column is the commit from the firmware version the library reports, and `on your Striso` when it
  is the version the connected Striso reported in this run.
- **Choosing a build plays it.** From anywhere: Virtual (restarts on the build in about 0.3 s),
  the Striso (its session ends, Virtual starts) or nothing. The build is remembered for the next
  Virtual start.
- **The same key.** After the switch the app presses the voice key you were on (the firmware's
  own `K` command), so key 26 that played the wind engine now plays the sax. The firmware picks
  the preset it remembers for that key; the app reads the voice back as always. Nothing is
  emulated: it is the key press the user would make.
- **⇄** goes back to the build played before this one (and forward again): the cross-build A/B in
  one click, on the same key. Within one build the A/B is the engine row: click wind, click sax.
- **Builds that cannot load are listed greyed with the reason** (the app probes each library once:
  its C API and firmware version, without keeping it loaded) and cannot be chosen. The reasons:
  built for another Striso Live (API n), not a striso_virtual library, the Microsoft C++ runtime
  is missing (Windows), kept in quarantine (macOS).
- **Install a release zip…** takes `striso_virtual-<version>-<platform>.zip` (checked against its
  manifest: platform, API, sha256), unpacks it into the firmware folder and plays it. A bare
  library file is copied in under its folder's name. **Open the firmware folder** shows where a
  build goes by hand.
- In Striso mode the left column has no build row: the Striso's firmware is what is flashed on
  it, shown in Setup › Firmware.

Setup › Firmware shows the running firmware: the Striso's version, or Virtual's build title with
its version, with a copy button. The picker is not duplicated there.

## 6. The audition loop

1. Virtual plays the current build (or the Striso plays). The coordinator drops
   `firmware/<audition>/striso_virtual.dll` (+ `manifest.json`) into the firmware folder.
2. Play › the build menu lists it by title. Click it. Virtual restarts on it; the same key plays
   the new sound; the engine row shows the build's engines.
3. Play. The hero knobs are the ones the build names (`StcH`).
4. `⇄`: the previous build on the same key. `⇄` again: back. Within the build: the engine row.
5. Verdict. A build that is rejected stays in the menu until its folder is deleted (Open the
   firmware folder).

## 7. Problems and their fixes

A problem shows as the banner strip under the header (bg2, error dot, the title in body text, the
sentence in text2, the action buttons as ghosts, a close) and, in Play, as the start screen's
title, sentence and buttons. The same object renders both. The status line shows the title.

| problem | title | sentence | actions |
|---|---|---|---|
| no Striso (you clicked Striso) | No Striso on USB | Plug it in and switch it on; it connects by itself. | Play Virtual |
| busy (after 30 s of quiet retries, or a direct click) | Your Striso is busy | Another program holds it: striso.py, the web app, a flash tool. Close it, then connect. | Connect Striso · Play Virtual |
| no driver (Windows) | No driver for the Striso | Interface 2 needs the WinUSB driver. Zadig sets it: Options › List all devices, Striso (Interface 2), WinUSB. | Connect Striso |
| Striso too old | This Striso needs a firmware update | Striso Live needs the current firmware; this Striso runs v2.2.3-…. Flash the latest release, then plug it in again. | Copy version · Play Virtual |
| USB off (`--no-usb`) | USB is off in this run | The app was started with --no-usb. | Play Virtual |
| connection lost (I/O error) | Connection lost | *the USB error* | Connect Striso · Play Virtual |
| no builds | No firmware builds for Virtual | Install a release zip, or put a build in the firmware folder. | Install a release zip… · Open the firmware folder |
| build built for another app | *Title* was built for another Striso Live | Its C API is 1; this app speaks 2. Ask for a rebuild, or pick another build. | Pick a build · Open the firmware folder |
| not a library | *Title* is not a striso_virtual library | *the loader's word* | Pick a build · Open the firmware folder |
| runtime missing (Windows) | Virtual needs the Microsoft C++ runtime | VCRUNTIME140.dll … missing: install the Visual C++ Redistributable 2015-2022 (x64). | Get the runtime · Pick a build |
| quarantined (macOS) | macOS keeps *Title* in quarantine | Downloaded files are quarantined and refused by dlopen. Striso Live can clear it. | Clear quarantine · Pick a build |
| build too old | *Title* is too old for Striso Live | It runs v…; the app needs StcX, Stcy and StcH. Pick a newer build. | Pick a build |
| Virtual did not start / come back | Virtual did not start | *the reason* | Play Virtual · Pick a build |
| no sound in Virtual | *(not a problem: the status line says "No sound: <why>")* | | Setup › Audio |
| no MIDI input in Virtual | *(not a problem: the Input menu says "No MIDI inputs on this computer"; the status says "input: on-screen")* | | |
| Through PC denied (macOS microphone) | *(Setup › Audio, as today: the permission sentence with the System Settings path)* | | |

`Pick a build` opens the build menu (section 5). `Get the runtime` opens
https://aka.ms/vs/17/release/vc_redist.x64.exe in the browser. `Clear quarantine` runs
`xattr -dr com.apple.quarantine` on the build's folder and tries again.

## 8. Firmware-side requests

The app cannot name an audition. Today it shows the folder name
(`2026-10-24_audition sax v1 (56f7266)`). Requested, for every build placed in the firmware
folder (release zips through `tools/package.sh`, audition folders through whatever places them):
a `manifest.json` next to the library with, besides the fields the release manifest already has
(`name`, `version`, `platform`, `library`, `sha256`, `api_version`, `firmware_version`, `commit`):

```json
{
  "title": "Sax v1",
  "description": "Soprano, alto, tenor and baritone on the wind key (26); the wind engine on key 16 for comparison."
}
```

`title`: a short name, as the user would say it (release builds: the version, e.g. `v2.2.4-308`).
`description`: one sentence, optional. The app reads nothing else new. No console command is
needed: the voice list, the voice keys and the hero knobs already come from the firmware.

## 9. macOS and Windows

The flows are the same. What differs is named where it happens: the library's file name
(`libstriso_virtual.dylib`), the quarantine problem and its fix (macOS), the WinUSB driver and the
C++ runtime problems (Windows), the microphone permission for Through PC (macOS, in Setup › Audio),
and how the firmware folder is opened (`open`, `explorer`).
