# Firmware ↔ app gaps

The firmware's console commands and settings that Striso Live doesn't expose, or uses only in
part. Checked against:
- combined 0ee43be, the current release line (v2.2.4-338);
- `next`, which adds:
  - mod-limits: StcW, the voice list past 128;
  - mod-stce: Stce, the loaded engines;
  - mod-presets: J j F x O, the sound presets.

The app is checked as of branch `gaps`, from voice-w.

Each gap gives its user value (for playing and play-testing) and its size, in app work plus any
firmware work. The firmware stays the source of truth: where the app can only show a value, it
shows the board's. Where a setting has no console command, the gap is the command.

## Done on this branch

| | what | how |
|---|---|---|
| 1 | **MIDI out, as the board has it.** The app read StcY's `midi ch voices bend vol sustain rate` and showed none of it. | Setup, MIDI OUT: the mode as the board's MIDI switches (StcX group midi: MPE · Poly · Mono), the selected one from StcY. A click presses the key (StcK) and the state is read back. Shown below it: "10 voices from channel 2 · pitch bend 48 semitones", then volume, sustain and rate. |
| 2 | **The MIDI monitor (StcM / Stcm).** The firmware reports every MIDI message it gets; the app used it only in a test. | The console drawer's **MIDI in** toggle: StcM on, each message in the log in words ("MIDI in · ch 1 · note on 60 velocity 100"); Stcm off. It's useful for checking that a controller reaches the board or Virtual. |

## Open

| # | gap | user value | size |
|---|---|---|---|
| 3 | **The settings dials from the app.** These can only be set on the instrument (Settings + tilt): MIDI channel and MPE voices, MPE bend range, volume (CC7), sustain, MIDI message rate, fine tuning. The app shows them (1) but has no command to set them. | High for play-testing MIDI setups: no more tilting a dial to find channel 3. | Firmware: a console command that sets a dial's value (the same path as the tilt gesture), about S. App: S (a slider per dial, read back from StcY). |
| 4 | **Per-preset settings in the config.** The 8 settings presets (iP1..iP8: name, colour, MIDI mode, channel, MPE bend, voice, tuning, mono legato, sound preset, the MIDI CC mappings Mpres/Mx/My/Mvelo, volume, decay) are written only by the board itself or `tools/striso.py`. The app's Save to Striso writes only the touch settings and key factors (into preset 1). | High once the dials (3) exist: "save this setup as settings preset 3". | App: M (records into the config UF2 through the existing Save flow, read back after the reboot); firmware: none. |
| 5 | **Mono legato per preset.** Settings key 9 switches it live (the app's Legato toggle); the preset setting `mono` keeps it, but only the instrument or the config sets it. | Medium. | Part of 4. |
| 6 | **A settings preset's sound** (`iP<n>sound`, mod-presets): which board preset a settings preset loads. | Medium: one key brings the sound and the setup. | Part of 4, after presets land. |
| 7 | **Scanner diagnostics:** StcE (counters), StcZ (every button's calibration state), StcR (record N seconds / dump), StcC (calibration reset, dangerous). Only reachable as raw console characters. | Medium for hardware trouble ("key 23 feels dead"), low for playing. | S for a read-only "Keys health" view of E and Z in Setup → Key equalizer. M with R's recording. C stays out (tools/striso.py, guarded). |
| 8 | **Actions without a K flag:** Flip (11), Send MIDI configuration (65), Reset (67) can't be pressed from the app. | Low to medium: Cfg is handy after changing a synth. | Firmware: mark Flip and Cfg pressable (`k`), S. App: none, since the overlay already presses switchable keys. |
| 9 | **The synth profile (StcP), threads (StcI), inbox lanes (Stcq).** These are developer diagnostics, reachable as raw console characters. | Low for users. Useful for engine work. | S: buttons in the console drawer that print them. |
| 10 | **StcY fields not shown:** alt, porta(mento), flip, led, updown. | Low: the board view shows the controls. | S. |
| 11 | **USB audio test tone (Stcu).** Only the bench uses it, along with the latency marker (Stcl) and the echo. | Low. | S. |
| 12 | **`next`'s StcW, Stce, presets.** Done on voice-w; it needs the next board build. | High. | Done; `minFirmware` is set when it merges. |

Not gaps: StcV, v, W, X, Y, y, H, K, N, p f g k, Q, L, U, t, S s, B (Save to Striso's bootloader)
and D (left to the tools).
