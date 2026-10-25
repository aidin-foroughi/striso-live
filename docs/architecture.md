# Striso Live: sessions, sound and routing

How the app connects, what makes the sound, where it is heard, and what the UI may know. This
replaces the old controller, where each mode (board, demo, virtual, audition, Through PC) added its
own booleans. What the user sees of it, flow by flow, is `docs/flows.md`.

## Principles

1. **Two modes, never mixed.**
   - **Striso**: the app manages and plays the hardware over its USB console (interface 2).
   - **Virtual**: a standalone soft instrument, the Striso firmware compiled for the computer.
   It holds no USB session with any Striso. It is played from MIDI/MPE controllers the OS sees
   (a Striso through its own USB MIDI port, a LinnStrument, a keyboard) and from the on-screen
   board.
   Switching modes is a full teardown of one, the same as Disconnect, followed by a start of the
   other.
2. **The firmware is the single source of truth.** The app displays what the board (hardware or
   virtual) last reported and asks it again after every request, on its change counter (`Stcy`)
   or on an event. It never models board state by guessing what a command did, and keeps no copy
   of firmware tables. When the UI needs something the firmware cannot tell, the firmware gets a
   read-only command: `StcX` (settings-key layout), `StcY` (state), `Stcy` (change counter), `StcH`
   (hero knobs).
3. **One `Board` interface.** Both modes give the UI a `Board`: the console protocol
   (`StrisoClient`: version, lists, voice select, parameters, `K`, `N`, `X`, `Y`, `y`, load), what
   plays it by hand, where Save writes, and a `lost` event. Voices, presets, parameters with undo,
   A/B, harmony, tuning labels, the settings overlay and the key equalizer talk only to the
   active `Board`.
4. **Current firmware only.** On connect the board must answer `StcX` and `Stcy`. If it doesn't,
   the session fails with one message: "This Striso needs a firmware update to work with Striso
   Live (found <version>)". There are no fallbacks for older firmware.
5. **The app ships no firmware.** Virtual loads a `striso_virtual` library at run time:
   - a build from `<app data>/firmware/<build>/` (the build menu in Play, docs/flows.md 5), an
     installed release zip, or `--virtual-lib`;
   - the library must report `sv_api_version() == 2` (`svApiVersion`), else the problem names
     the build and offers another; a build is probed once (its API and firmware version, without
     keeping it loaded) so the menu greys out the ones that cannot run;
   - choosing a build plays it: whatever plays is torn down, the library closed, the new one
     loaded and checked, Virtual started on it, and the voice key the user was on pressed (`K`).
6. **Nothing runs that the session does not need.** Disconnect leaves:
   - no USB handle;
   - no audio device open;
   - no MIDI input open;
   - no virtual board;
   - no timers or pollers.

## The pieces (`lib/src/session/`, pure Dart unless noted)

| piece | job |
|---|---|
| `SessionMachine` | the states and every transition, in one place; no I/O (unit tested transition by transition) |
| `Resources` | what runs right now, by name (console, stream, pollers, audio input, output, virtual board, MIDI inputs); the status line and the Disconnect test read it |
| `Session` | drives the machine: opens the mode's `Board`, keeps it alive (lost, reboot, reconnect), owns the pollers, ends everything on Disconnect |
| `Board` / `StrisoBoard` / `VirtualStriso` | the active instrument (see above) |
| `SoundRouting` | tells the audio engine what to do in each state; the virtual board's clock; MIDI inputs into the virtual firmware |
| `BoardState` | the last `StcY` reply, the `StcX` layout, the tuning (`StcN`); refreshed when `Stcy` changes |
| `ParamsModel` (`lib/src/params_model.dart`) | the live parameters with undo, A/B, Mutate, Reset and the read-back of the board's values |
| `VirtualStrisoRuntime` (`lib/src/virtual_support.dart`) | the build chosen (its library loaded when chosen, unloaded when another is; a `LoadFailure` kept when it did not load), the instrument, its flash kept on this computer |
| `AppController` (Flutter) | the composition root and the UI's façade: widgets read it and call it, no logic in widgets |

### States

```
             connect(m)                 opened+ready
  Idle ─────────────────▶ Connecting(m) ─────────────▶ Live(m)
   ▲  ▲ ◀── disconnect ──┤    │ fail                     │ reboot (Save, reset)
   │  │                  │    ▼                          ▼
   │  │   disconnect     │  Failed(m, kind) ◀── fail ── Rebooting(m) ── back ──▶ Connecting(m)
   │  └──────────────────┘    │ connect(m)
   │                          └──────────────▶ Connecting(m)
   │ lost (unplug, I/O)                         from Live, Connecting
   └── Idle(lost) ── found (board back, user left it connected) ──▶ Waiting(m) ── due ──▶ Connecting(m)
```

- **Idle**: nothing open. It carries why: never connected, disconnected by the user (the Striso
  stays away), Virtual stopped by the user, unplugged, connection lost. The presence poll runs in
  Idle unless the user disconnected the Striso: one that appears connects by itself (4 s after
  it appears, so a flash tool gets it first); at start a Striso on USB connects right away.
- **Waiting(m)**: a Striso was found (or was busy) and a connect is due at a set time (4 s after it
  appears, so a flash tool gets it first; busy retries for 30 s). Cancel goes back to Idle.
- **Connecting(m)**: opening the board, the version, the capability check, the lists.
- **Live(m)**: the board answers. Striso: Through PC as the user chose. Virtual: its output and
  MIDI inputs.
- **Rebooting(m)**: Save to Striso or a reset; the board goes away on purpose and comes back by
  itself. Lost events are expected here.
- **Failed(m, kind)**: `busy`, `noDriver`, `notFound`, `needsUpdate`, `library` (missing or wrong
  API), `noUsb`, `other`. Nothing stays open. The session never shows prose for a failure: the
  controller derives a `Problem` (title, sentence, fixes) from the state and the virtual runtime's
  `LoadFailure`, and the banner strip and the start screen render it (docs/flows.md 7).

Mode switch = `disconnect` then `connect(other)`. The machine refuses transitions that make no
sense (e.g. `ready` while Idle) and says so in the log.

## Sound and routing

| state | the audio engine (`ThroughPc.route`) | MIDI | virtual board |
|---|---|---|---|
| Idle, Waiting, Failed, Connecting(Striso), Rebooting(Striso) | `off`: no device open | closed | none |
| Live(Striso) | `input`: the Striso's USB audio input (Through PC to the output when on; Record) | closed | none |
| Connecting(Virtual), Live(Virtual), Rebooting(Virtual) | `source`: the output alone, playing the virtual board | the chosen inputs, raw bytes into `sv_midi_write` | runs |

- **Output** is the computer's output for Virtual (the same output, buffer (Auto), exclusive mode
  and gain as Through PC, and the same granted-mode and latency rows). For Striso it is the
  instrument's jack, plus the computer when Through PC is on.
- **Through PC exists only in Striso mode**: "hear the Striso's USB audio on this computer".
- **The virtual board's clock never depends on the output.** It renders inside the output's
  callback (`sa_set_source` with `sv_audio_source`) while the output runs. When the output does
  not open or stalls, it runs on its own real-time thread and the status says "No sound: …".
  Detaching the source waits until the callback has left it (`sa_set_source` returns then), so
  the board can be destroyed right after.
- **MIDI**: the chosen inputs are opened while Virtual is live (WinMM / CoreMIDI in the
  `striso_audio` library). Bytes go from the driver thread through a parser to
  `sv_midi_write` (USB-MIDI packets) with no Dart on the path. The firmware's own MIDI input
  handles them. The app maps nothing. Hot-plug: re-enumerated every second while live; a chosen
  input that comes back is reopened.

### The status line

One line from the state and the resources, e.g.:
- "Striso · Through PC → Headphones (TBT200 Dock)"
- "Virtual · Sax v1 → Headphones (TBT200 Dock) · input: LinnStrument"
- "Virtual · Sax v1 · No sound: the output would not open (Headphones) · input: on-screen"
- "Not connected", "Striso found · connecting in 4 s", "Unplugged", "Stopped", a problem's title

## Board state, not app state

- The current voice, parameter values, MIDI mode, tuning, transposition, settings values and LED
  colour come from the board: `Stcv`, `p/f/g/k`, `StcN`, `StcY`.
- `Stcy` is polled cheaply (every 250 ms while live). When it moves, `StcY`, the voice list and
  the parameters are read again. A change on the instrument (Settings + key, octave buttons) or
  behind the app's back (a console write) shows up without app-side logic.
- Edits: a knob sends its value at once, and the knob shows it as pending until the board's
  read-back at the gesture's end.
- Undo/redo, A/B, Mutate, Reset and Recall write and then read back. The history keeps what the
  board reported before and after.
- The hero knobs are the ones `StcH` names for the current voice (read on connect and when `Stcy`
  moves). A name its parameter list lacks is shown as an error, never replaced by a guess.
- The settings overlay is drawn from `StcX` (kind, group, engine, LED colour, whether `K` takes
  it). The Dart mock board (widget tests only) answers `X` with a recording of the firmware's
  reply.

## Save

- **Striso**: as before. The bootloader drive named in `INFO_UF2.TXT`, a backup of `CONFIG.UF2`,
  `NEWCFG.UF2` inside the config area, the restart, the read-back.
- **Virtual**: the same flow on the virtual board's own bootloader drive. Its config flash is then
  kept at `<app data>/virtual/flash.bin` and boots the next virtual board.

## Tests

- `test/session_machine_test.dart`: every transition, refused ones, errors and reboots.
- `test/disconnect_test.dart`: connected with Through PC playing on the fake audio backend, then
  Disconnect. It asserts no USB transport open, no audio device configured, and no pending timers
  (fake_async), and that the status says so.
- `test/virtual_board_test.dart` (needs a `striso_virtual` build):
  - both modes on the virtual firmware: lists, voice switch, undo, parameters, the settings
    overlay from `StcX`, Save, reset and reconnect;
  - a change made behind the app's back converges in the UI;
  - Virtual plays with Through PC off;
  - a dead output never stops the board;
  - MIDI bytes reach the firmware unchanged (its MIDI monitor, `StcM`);
  - a library loaded, unloaded and switched; a wrong one refused.
- `packages/striso_audio/test/midi_test.dart` and the native self-test: the MIDI parser, the
  sink, hot-plug, the source guard.
