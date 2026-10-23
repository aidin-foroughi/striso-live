# Striso Live: design spec

Scope: the visual and interaction design for the three-tab layout (Play, Sound, Setup) plus header
and console drawer. Everything here is implementable from `lib/src/theme.dart` outwards; data and
behaviour already exist in `controller.dart` and `striso_core`.

## 1. Direction

A quiet instrument panel, not a dashboard. Near-black neutral ground, warm off-white type, one
accent. Colour belongs to the music: the eight engine colours and the pressure heat on the board
are the only saturated things on screen, so when a key lights up, it is the brightest thing in the
window. Chrome recedes: no cards, no seams, no gradients, no glows on buttons. Hierarchy comes from
spacing, type size and text colour; a hairline appears only where something is editable (an input)
or draggable (the drawer edge).

Remove: the purple tint, the 1px seam grid, bordered tiles with colour stripes and glow, the second
accent (glacier) and lilac, radial key gradients, dashed pitch guides, the modal "plug in" card,
index numbers on presets, the footer shortcut line, the stats line ("0 keys down, 62 messages/s").

## 2. Tokens

### Colour (dark, default)

| role | value | use |
|---|---|---|
| bg0 | `#0E0E11` | window |
| bg1 | `#151518` | board plate, drawer, popover body |
| bg2 | `#1D1D22` | hover fill, secondary button, input |
| bg3 | `#26262C` | pressed / selected fill, knob track |
| hairline | `#2B2B33` | input edge, drawer edge, focused rows only |
| text1 | `#F2EEE6` | primary text, values |
| text2 | `#A5A19A` | labels, secondary |
| text3 | `#66635E` | hints, disabled, out-of-scale labels |
| accent | `#F0C75E` | selection, primary button, root key, knob arc, focus ring |
| accentInk | `#1A1507` | text on accent |
| ok | `#6FD98A` | connected dot, saved |
| warn | `#F0C75E` | same as accent (never both meanings in one row) |
| error | `#FF6B6B` | lost connection, destructive, failed save |
| demo | `#7FB2FF` | demo dot and demo chip only |

Engine colours (tuned to near-equal lightness, L* ≈ 68–74, on bg0; trumpet's cyan is ΔE ≥ 31 from
modal, ≥ 54 from wind and ≥ 70 from the accent for normal, protan and deutan vision):

| engine | value | | engine | value |
|---|---|---|---|---|
| strisy | `#B9B9C2` | | wind | `#5FD37A` |
| va | `#FF8A3D` | | ep | `#B48CFF` |
| modal | `#5CA8FF` | | brass | `#E9A23B` |
| bowed | `#FF5A5A` | | trumpet | `#2BB7C9` |

Rule: engine colours appear only on the engine selector, the current preset's dot, the current
sound's name in headers, and the settings-key overlay. The accent is never placed in the same row
as the engine row (brass and accent are close on purpose; they must not meet).

Pressure heat ramp (p = 0..1, interpolate in sRGB): `0 → #F0C75E`, `0.5 → #FF8A4C`,
`0.85 → #FF5C6C`, `1 → #FFF1F3`. Alpha of the key fill = `0.25 + 0.75·p`.

Opacity steps for text on text1: 100 / 68 (≈ text2) / 42 (≈ text3) / 24 (disabled).

Light theme (optional, same roles): bg0 `#F4F2EE`, bg1 `#FFFFFF`, bg2 `#ECE9E3`, bg3 `#E0DCD4`,
hairline `#D3CFC7`, text1 `#1A1917`, text2 `#5E5B55`, text3 `#9A968E`, accent `#B8860B`,
accentInk `#FFFFFF`. Engine colours darkened 15% L*. Heat ramp unchanged. Ship dark first.

### Typography

Bundle **Inter** (variable, one file, OFL) for identical metrics on Windows and macOS; features
`tnum` everywhere, `cv11` (single-storey a) off, `ss01` off. Fallback `Segoe UI`, `Helvetica Neue`.
Serif for roman numerals only: `Georgia` (on both OSes). Mono for the console only: `Cascadia
Mono` / `Menlo`.

| token | size/line | weight | use |
|---|---|---|---|
| micro | 11/14 | 500, uppercase, +0.08em | group names, column labels |
| small | 12/16 | 400 | hints, secondary values |
| body | 13/18 | 400 | controls, lists, knob labels |
| title | 15/20 | 600 | section titles, engine name |
| sound | 20/24 | 500 | current preset name |
| chord | 36/40 | 500 | chord name in the strip |
| roman | 32 (Georgia) | 400 | roman numeral |
| stage | 48/52 | 500 | stage-mode chord name |

Only weights 400, 500, 600. Numbers always tabular.

### Spacing, radii, borders

Spacing scale: 4, 8, 12, 16, 24, 32, 48. Outer window gutter 16; column gap 24; control gap 8;
list row 28 high; toolbar 36 high; header 48 high.
Radii: 4 (buttons, inputs, chips), 8 (popover, toast), 12 (dialog), full (dots, knobs, toggles).
Borders: none for layout. Hairline 1px on inputs and the drawer edge. Focus ring: 1px accent
outside, 2px offset. Elevation only for popovers, menus, dialogs and toasts: bg1 fill + shadow
`0 8 24 rgba(0,0,0,0.55)`.

### Motion

| name | duration | curve | use |
|---|---|---|---|
| quick | 120 ms | easeOut | hover, press, toggle |
| tab | 180 ms | easeOutCubic | tab content: fade + 4px rise |
| open | 240 ms | easeInOutCubic | Morph / console / column collapse |
| stage | 320 ms | easeInOutCubic | enter and leave stage mode |
| pressure | τ 16 ms up, τ 110 ms down | exponential | key fill (keep current) |
| strike | 450 ms | cubicOut | strike ring |
| toast | 180 ms in, 240 ms out | easeOut / easeIn | slide 8px + fade |

Reduced motion (OS setting via `MediaQuery.disableAnimations`, or `--reduced-motion`): no strike
or release rings, no connect sweep, no slide (fades only, 80 ms), pressure fill follows input
directly. Pressure colour is data, it stays.

## 3. Tabs

Header, 48 px, always present:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ◉ Striso Live        Play   Sound   Setup                 ▁▂▃▂▁ 12%  ● Connected  [Disconnect]│
└──────────────────────────────────────────────────────────────────────────────────────────┘
```
Brand mark + name (title, text1 / text2). Tabs centred, body 500, selected text1 with a 2 px
accent underline 8 px narrower than the label; others text3, hover text2. Right: CPU sparkline
56×14 px (text3 line, accent when > 70%) with the value in small; status dot 8 px + status in
body text2; Connect / Disconnect as a secondary button (primary when disconnected and a board is
found). Clicking the status text opens the console drawer.

Console drawer: pulled up from the bottom edge (a 6 px grab zone, hairline on hover), 240 px
default, mono 12, bg1. Header row holds Clear, the log path and the "Stc +" command field. Also
toggled with `` ` ``.

### Play (default)

```
1480×960
┌ header 48 ─────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│ ○ ● ○ ○ ○ ○ ○      C ▾  Major ▾  D4 | D | 1 2 3 | do re | —   Transposed +1 oct ✕   viola · bowed      │
│ Bowed                                                                             bow force  bow speed │
│ bowed string      ┌──────────────────────────────────────────────┐                ◔          ◑         │
│ violin            │                                              │                bow pos    rosin     │
│ ● viola           │                                              │                ◔          ◑         │
│ cello             │               the board                      │                body       damping   │
│ bass              │            ~860 × 756 px                     │                ◑          ◔         │
│ …                 │                                              │                vibrato    vib hz    │
│ MY SOUNDS         │                                              │                ◔          ◑         │
│ warm viola  ⋯     │                                              │                reverb     delay     │
│ glassy  ⋯         └──────────────────────────────────────────────┘                ◑          ○         │
│ + Save current    F          I  tonic     Chords: I  IV  V  vi  ⋯  Clear   C major · Sounds like F major · Use │
│                   one note                                                        Edit in Sound →      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
  220       24                      centre (fills)                         24      260
```

Left column, 220 px: the engine row (eight 24 px round buttons, 8 px gaps, pinned), engine name
(title) and blurb (small text3), this engine's presets as 28 px text rows, then `MY SOUNDS`
(micro) with the user's sounds for this engine (hover `⋯`: Recall, Rename, Export, Delete) and a
ghost "+ Save current" row. The list scrolls on its own.

Centre: board toolbar (36 px): key root select (disabled when scale is Off), scale select,
note-label segmented control, a transposition chip when transposed (click resets). The hover
readout (note, pressure, velocity, tilt) sits at the toolbar's right end in small text2 while a
key is hovered. The board fills the remaining height; the harmony strip (96 px, 4.4) sits under it.

Right column, 260 px: current sound name (sound, text1) with the engine in its colour (small),
6–8 hero knobs in two columns of 56 px (idea 2 says which), 24 px gap, Reverb and Delay amounts
(`rv_mix`, `dl_mix`; an effect that is off shows its knob at 40%, click enables), then an
"Edit in Sound →" ghost link.

Narrower widths. 1280–1479: right column 220, knobs 48 px. 1100–1279: left column 180 (engine
buttons 20 px); the right column becomes a horizontal knob strip (44 px, 8 + reverb/delay)
between board and harmony strip; the sound name moves to the toolbar's right. 1000–1099: the
progression chips fold into a "Chords ▸" popover and the segmented control goes icon-only.
Minimum window 1000×700.

Visible: engines, presets, board, key/scale, hero knobs, chord strip. Tucked away: all other
parameters (Sound), motion (Setup), stats and diagnostics (console), Refresh (engine row `⋯`).

### Sound

```
┌ header ────────────────────────────────────────────────────────────────────────────────────┐
│ viola · bowed          ↶ ↷   Reset   Mutate ▾   A/B   [Save sound]                ⋯        │
│                                                                                            │
│ LEVEL      BOW                                       STRING        │ CHORUS  ⬭ on            │
│ ◔ level    ◔ bow force ◔ bow speed ◔ bow pos ◔ rosin ◔ damping ◔ inharm │ ◔ rate ◔ depth ◔ mix  │
│ BODY                    MOD                                        │ DELAY   ⬭ off           │
│ ◔ body ◔ body size      ◔ vibrato ◔ vib hz                         │ ◔ time ◔ sync ◔ fb ◔ mix│
│                                                                    │ REVERB ⬭ on  TREMOLO ⬭ off│
│                                                                    │ ◔ size ◔ damp ◔ mix …   │
│                                                                    │ MY SOUNDS   all · bowed │
│                                                                    │ warm viola  ⋯  glassy ⋯ │
│                                                                    │ Import   Export all     │
│ ▸ Morph                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

Top row (48 px): sound name + engine colour; undo / redo icon ghosts; Reset (ghost, enabled when
any value ≠ loadValue); Mutate (secondary) with a `▾` popover for scope and amount; A/B (see 6);
Save sound (primary when edited) opens a name field inline in My sounds; `⋯` holds Copy as C.

Voice parameters: groups in firmware order, each a micro label then 44 px knobs in a flowing row
(8 px gaps, 24 px between groups), no boxes; on/off parameters are inline toggles. Effects: a
fixed 300 px column, one group per effect with its toggle in the micro label row; an off
effect's knobs sit at 40% opacity but stay editable. My sounds below, filter all · current
engine, rows with engine dot and hover `⋯`; Import / Export all as ghosts.

Morph: a collapsible bar at the bottom, closed by default (`▸ Morph`, plus source and "3 corners"
in small text2 when it has state). Open: 260 px; pad 220×220 left (bg1, 2×2 hairline grid,
12 px accent handle, 1 px trail when orbiting), four corner slots (A–D 24 px lettered circles,
label, Capture / Replace / Clear), source segmented Hand · Orbit · Tilt, orbit speed, "Include
effects" toggle. One undo entry per gesture (existing).

Below 1200: the effects column moves under the voice parameters; My sounds becomes a popover
from a top-row button.

### Setup

```
┌ header ────────────────────────────────────────────────────────────────────────────────────┐
│  Sensitivity | Key equalizer | Settings keys          D4 | D | 1 2 3 | do re | —           │
│ ┌──────────────────────────────────────────────┐    SENSITIVITY                              │
│ │                                              │    Pressure     ────────●────── 1.00  ↺    │
│ │                                              │    Velocity     ─────●───────── 0.80  ↺    │
│ │        the board, ~800 px wide               │    Tilt         ────────●────── 1.00       │
│ │        showing the mode's overlay            │    Bend         ───●─────────── 0.50       │
│ │                                              │    Threshold    ●────────────── 0.000      │
│ │                                              │    Changes are live. Save to keep them.     │
│ │                                              │                                             │
│ │                                              │    [Save to Striso]  Saved 14:02:11 ✓       │
│ └──────────────────────────────────────────────┘                                             │
│  hover: Eb4 · key 31 · pressure 0.412 · ×1.05        MOTION        ◎ 0.95 g   rot x ─●─    │
│                                                       FIRMWARE     2026-10-22 v2.2.4-46 … ⧉  │
│                                                       Console ▸                             │
└────────────────────────────────────────────────────────────────────────────────────────────┘
   board column (fills)                               24     360
```

The mode segmented control (toolbar left) changes both the board overlay and the right column:

- Sensitivity: five sliders (log scale for pressure and velocity), tabular value, `↺` ghost when
  ≠ default, one help line shown on hover only.
- Key equalizer: board shows per-key factor tint and last-press arc (existing drawing; warm =
  heat 0.5, cool = demo blue, near-median = ok). Right: selected key (follows presses when
  Follow is on), factor slider ×0.50–×2.00 with ÷ × steps, pressure trace 300×60, Suggest,
  Reset key, Reset all, Clear measurements.
- Settings keys: board shows each key's firmware function (4.1); right shows the hovered or
  selected key's title, knob behaviour and detail, and for voice keys the engine's presets as
  rows. Two-line "how to" on top, the rest behind "More ▸".

Always in the lower right: Save to Striso (primary; disabled with the reason in a tooltip), the
save status line (small; ok / error; during a save a 2 px indeterminate accent bar and the step
text), Motion (120 px: tilt disc, three rotation bars, "no data" in text3), Firmware version with
a copy icon, "Console ▸" ghost link.

Narrower widths: below 1200 the right column is 300; below 1100 the Motion and Firmware rows move
under the board in one line.

## 4. Components

### 4.1 Key (board)

Geometry: disc radius r = 7 mm × scale; label at r×0.72 (min 11 px); octave digit at r×0.4,
baseline-aligned, 2 px right of the name.

| state | fill | rim | label |
|---|---|---|---|
| idle natural | `#222227` | none | text1 @ 70% |
| idle accidental | `#19191D` | none | text1 @ 42% |
| scale on, in scale | as idle | 1 px text1 @ 18% | text1 @ 85% |
| scale on, out of scale | as idle | none | text1 @ 28% |
| scale on, root | as idle | 1.5 px accent | accent |
| enharmonic spelling | as in-scale / root | same rim @ 50% | same @ 70% |
| hover (demo play or Setup) | +4% lightness | 1 px text2 | unchanged |
| pressed | heat(p) fill, alpha `0.25+0.75p`, radial from the tilt point (offset `x·0.4r`, `−y·0.4r`), halo to `r(1+0.6√p)` at alpha `0.25p` | 1.5 px heat(p) | p < 0.35: text1; else accentInk @ 85% |
| tilt | a 3 px dot in `#FFFAF0` @ 90% at the tilt point; no needle | | |
| strike | ring from `1.0r` to `1.5r + 0.6a·r`, width `2.5a px → 0`, colour `#FFF1E6`, alpha `0.9a → 0`, 450 ms cubicOut | | |
| release | fill decays with τ 110 ms; no ring | | |
| key-EQ overlay | factor tint disc @ alpha `0.5·min(1, 1.6·|log2 f|)` (warm > 1, demo-blue < 1), arc at r+2 px for last peak, `×1.05` under the name in small | | |
| settings overlay | keys without a function: fill bg0 @ 78%; with one: rim 1.5 px in group colour, voice keys in the engine colour, current engine filled 15% of its colour, label = short name, sub-label = preset, danger keys label error | | |
| selected (EQ or settings) | | 2 px accent at r+3 | |

Pitch guides: no dashed lines; `C3 … C6` in micro text3 at the right plate edge. Control buttons:
outline text1 @ 30%; lit: accent fill @ 35% + accent outline, 300 ms fade. LED: 3 px dot, ok when
connected, else text3. Plate: bg1, radius 9 mm × scale, no stroke.

### 4.2 Knob and slider

Knob: 44 px (hero 56, strip 44, inline 36). Track arc 270° (from 7:30 to 4:30), 2 px, bg3. Value
arc 2 px accent, from the minimum, or from 12 o'clock for bipolar ranges (min < 0 < max). Centre
disc bg2 with a 2 px indicator tick in text1. Label under in body text2; while hovered or
dragging the label is replaced by the value (tabular, text1) plus unit if any. Modified marker
(value ≠ loadValue): a 4 px accent dot at the label's right. Locked against Mutate: a 10 px lock
glyph in text3 at the top right; `Alt+click` toggles. Interaction unchanged: drag vertical (Shift
fine), scroll, arrows, double-click resets to loadValue. Integer knobs snap with a detent haptic
substitute: the tick jumps, no tween. Toggle: 28×16 pill, bg3 off / accent on, 12 px knob
white; label right in body.

Slider (Setup only): 4 px track bg3, filled part accent, 14 px thumb text1 with bg0 2 px ring;
value right-aligned in body tabular, 56 px wide.

### 4.3 Engine and preset selector

Engine button: 24 px circle, 1.5 px ring in the engine colour, transparent inside. Hover: ring
2 px, tooltip with name and blurb. Selected: filled disc in the engine colour; strisy's grey
disc gets an accentInk centre dot so it reads as "on". Missing from this firmware: ring @ 30% and
a tooltip "not in this firmware". Keyboard `1`–`8`. Switching engine selects its remembered
preset (existing `voiceKeyAction`).

Preset row: 28 px, body text2, hover bg2, current: text1 500 with a 6 px engine-colour dot at
the left; pending (board not yet confirmed): text at 50% with a 1 px indeterminate bar under the
row. User sound row: same, plus `⋯` on hover, and an "edited" accent dot when it is the recalled
sound and values changed since. Filter and search are not needed (max 14 presets per engine).

### 4.4 Chord / harmony strip

96 px tall, three zones:

- Left (fixed 280): chord name in `chord` type text1 (one note: the note name; nothing held: last
  chord @ 42% until the next); under it the long name in small text2 ("one note", "major
  seventh, first inversion").
- Middle (flex): roman numeral in Georgia 32 accent, function word (tonic, dominant …) in small
  text2 next to it; then the progression as ghost chips 24 px (serif numeral or chord name,
  text2, hairline on hover only), newest right, auto-scrolls, `Clear` ghost at the end.
- Right (fixed 300, right-aligned): key name in body text1 ("No key" text3), and when a
  suggestion exists "Sounds like F major · Use" with Use as a ghost link in accent.

Nothing in the strip animates except a 120 ms crossfade of the chord name.

### 4.5 Tab bar, buttons, inputs, toasts, empty states

Buttons, all 28 px high, radius 4, body 500, padding 0 12:
primary accent fill / accentInk; secondary bg2 fill / text1, hover bg3; ghost no fill / text2,
hover text1 with bg2; danger ghost in error. Disabled: 35% opacity, cursor basic, tooltip with
the reason where one exists (Save to Striso, Mutate, Use).
Icon buttons: 28×28, same states, always with a tooltip.
Segmented control: ghost segments in one row, selected segment bg3 / text1, no outer border.
Select: bg2, 28 px, chevron text3, menu as popover (bg1, shadow, 28 px rows, hover bg2).
Text input: bg0, hairline, focus hairline → accent, placeholder text3.
Toasts: bottom right, 16 px from the edges, max 4 stacked, bg1 + shadow, radius 8, 12 px pad,
body text1, leading 6 px dot (ok / accent for warn / error), auto-dismiss 2.6 s (errors 6 s),
hover pauses, click dismisses. Persistent problems (banner today): a 32 px strip under the header,
bg2, error dot, body text, trailing `✕`; info variant uses text2 dot.
Empty states: one sentence in body text2 at the top of the area, optionally one ghost action;
never a box. Copy: "Connect to see this voice's parameters." / "Sounds you save appear here." /
"Chords you play line up here."
Dialogs (confirm save, code view): bg1, radius 12, 24 px pad, title + body + buttons right.

### 4.6 Connection states

| state | dot | header text | elsewhere |
|---|---|---|---|
| disconnected | hollow 1 px text3 | Not connected | board at 45% opacity; centred on it, no card: "Plug in your Striso" (title), one sentence (body text2), `[Connect]` primary + `Try the demo` ghost |
| board found, waiting | accent, pulsing 1 s | Striso found, connecting in 4 s | button reads Cancel |
| connecting | accent, pulsing | Connecting… | the invite shows the step in accent small |
| connected | ok | Connected | the connect sweep: label brightness ripples left to right once, 600 ms |
| lists loading | ok | Connected · reading parameters | knobs render as tracks without arcs |
| rebooting / saving | accent, rotating 270° arc | Saving to the Striso… | Save button shows the indeterminate bar; board dims to 60% |
| lost / unplugged | error | Unplugged | persistent strip with the reconnect sentence |
| busy | accent steady | Board busy | strip: "Another program holds the board." |
| demo | demo blue | Demo | a small `DEMO` chip (micro, demo colour) next to the sound name; keys are clickable |

## 5. Board visualisation

The board reads as an instrument at rest and as light while playing, and the two never compete.

- Rest: a dark plate with slightly lighter discs; naturals lighter than accidentals draws the
  layout's structure without lines. Labels are the quietest layer.
- Scale: label strength and a faint rim, never fill. A pressed key looks the same in or out of
  scale, so pressure is never confused with scale colour. Only the root has an accent rim.
- Pressure: a warm fill growing from the tilt point (heat ramp) with a halo that bleeds onto the
  plate. It is the only saturated warm colour on the plate, so the eye finds it instantly.
- Tilt and bend: the fill's origin and the white dot move with the finger (forward = up,
  sideways = bend). No needle: the offset origin is enough and keeps the label legible.
- Strike: one thrown ring scaled by velocity; soft strikes barely show, hard ones flash.
  Release: the fill cools and fades.
- Chords: held notes are lit by pressure; the strip names the chord. No chord highlighting on
  the board. A selected key (EQ or settings mode) alone gets an accent ring at r+3 px.
- Legibility: label flips to dark ink above p = 0.35; minimum 11 px; under 700 px board width
  the "D4" mode draws letters only. `C3…C6` labels at the right edge explain the pitch axis.
- Performance: keep the static picture layer; draw only lit, struck or hovered keys in the
  dynamic layer (existing). Drop halos above 20 lit keys.

## 6. Other good ideas, ranked

1. **Stage mode** (`F` or F11, Esc leaves). The board fills the window; the header shrinks to a
   24 px strip (dot, sound name, CPU); the chord strip overlays the bottom 80 px at 60% bg0 with
   the `stage` type; no columns, no toolbar; label sizes ×1.3. Why: on stage you need the board
   and the chord from two metres away. Implementation: a `stage` flag in the controller, a
   different `HomePage` layout branch, 320 ms transition.
2. **Hero knobs per engine/preset.** A `const Map<String, List<String>> heroParams` in
   `striso_core` (e.g. bowed: `bow_force, bow_speed, bow_pos, rosin, body, damping, vibrato,
   vib_hz`; va: `cut_base, res, cut_env, drive, saw2_detune, sub, release, vibrato`), with
   optional per-preset overrides keyed by voice name. Fallback: the first 8 continuous params
   in group order. Why: the Play tab must offer the right six knobs, not the first six.
3. **Restore the edited sound after a reconnect.** The board forgets edits on reboot (Save to
   Striso, power cycle). Keep the last snapshot per voice in the store; on reconnect, if the
   board's values differ, toast "Your edited viola is back: Restore" with a ghost action.
   Why: the one thing that loses a sound mid-rehearsal. Implementation: `snapshot()` on every
   `history.commit`, compare in `refreshParams(voiceChanged: true)`.
4. **A/B compare.** Hold the A/B button (or `B`) to hear loadValues; release returns the edits.
   Click toggles. Why: judging an edit against the preset is how sounds get finished.
   Implementation: `setValue(record: false)` for all voice and fx params, swap back, no history.
5. **Set list.** Star any preset or user sound; the stars form a Set list at the top of the Play
   left column, stepped with `PageDown`/`PageUp` (and shown in stage mode as "3/8 · glassy").
   Why: switching across engines mid-set in one keystroke. Implementation: an ordered list of
   voice names + optional user-sound names in the store; `recallPreset`/`selectVoice`.
6. **Shortcut overlay** (`?`) and a tidy set: `1–8` engines, `[` `]` presets, `PgUp/PgDn` set
   list, `Ctrl+S` save sound, `Ctrl+Z/Y` undo/redo, `M` mutate, `B` A/B, `F` stage, `` ` ``
   console, `Ctrl+1/2/3` tabs. Why: hands stay on the instrument. Implementation: extend
   `_onKey`, one overlay widget listing them in two columns.
7. **Expression monitor** (Setup, under Sensitivity). A 4 s scope of the last touched key:
   pressure, tilt y, bend x as three lines (accent, text1, demo blue), the note-on threshold as
   a hairline. Why: setting sensitivities by feel is guesswork; seeing the curve makes it a
   minute's job. Implementation: reuse the key-EQ pressure trace buffer, add x and y.
8. **Intonation readout** for non-12-TET tunings. If the stream carries pitch (or once the
   firmware exposes the tuning table), show cents from 12-TET under each held note's name in the
   strip. Why: the Striso ships 31-TET and just tunings and nothing in the app tells you what you
   are hearing. Implementation: only when pitch data exists; otherwise show the tuning name only.

Skipped as gimmicks: chord-tone suggestions on the board, animated backgrounds, per-key colour
themes.

## 7. Delete or merge from the current UI

- Delete the seam grid, panel cards, tile borders, colour stripes, selection glow and gradients.
- Delete the stats line (keys down, messages/s) from the view; keep the numbers in the status
  tooltip and the console.
- Delete the dashed C pitch guides and the tilt needle; keep the C labels and the tilt dot.
- Delete the release ring and the second accent (glacier) and lilac.
- Delete preset index numbers from tiles (tooltip only) and the "Refresh" button (engine row `⋯`).
- Delete the footer shortcut line and the modal invite card (inline invite on the board).
- Delete the long settings "how to" block; two lines plus a disclosure.
- Merge Morph into Sound as the collapsible bar; it leaves Play.
- Merge the Probe line into the board toolbar's right end (hover readout).
- Merge BannerBar into the toast system as the persistent strip.
- Merge Motion into Setup; remove it from the Play board area.
- Move "Copy as C" into the Sound `⋯` menu.
- Keep the serif roman numerals, the undo model, the key-EQ drawing logic and the static/dynamic
  board layers; restyle only.
