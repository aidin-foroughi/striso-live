// What every key does in the Striso's settings mode (the Settings button held), from the firmware:
// striso-control-firmware/synth_control.cpp config_but() and config_voice() (the current,
// non-OLD_CONFIG_LAYOUT layout). Keys are button ids, the same as the key stream's.
// test/settings_map_test.dart checks this table against the firmware source.
// Port of tools/app/js/settings.js.

import 'protocol.dart' show VoiceEntry;
import 'tuning.dart' show factoryTunings;

const List<String> howToSettings = [
  'Hold the square Settings button (bottom left) and press a key: the key does its setting instead of playing.',
  'While still holding the key, tilt it forward or back to step the value, or circle the tilt like a knob. The up/down leds show the value.',
  'Release the key, then the Settings button. Changes last until the Striso is switched off; settings presets 1 to 8 load stored settings.',
  'With Settings held, the octave buttons move by a semitone, and both together reset the transposition.',
];

class SettingsGroup {
  static const midi = 'MIDI mode', layout = 'Layout', sens = 'Sensitivity', voice = 'Voice', tuning = 'Tuning';
  static const preset = 'Settings preset', midi2 = 'MIDI', system = 'System';
  static const order = [midi, layout, sens, voice, tuning, preset, midi2, system];
}

/// Rim colours of the groups (0xRRGGBB).
const Map<String, int> groupColors = {
  SettingsGroup.midi: 0x8fdcec,
  SettingsGroup.layout: 0x8fdcec,
  SettingsGroup.sens: 0xf4d27a,
  SettingsGroup.voice: 0xffffff,
  SettingsGroup.tuning: 0xb9a3ff,
  SettingsGroup.preset: 0x8fe3a4,
  SettingsGroup.midi2: 0x8fdcec,
  SettingsGroup.system: 0xff8a65,
};

class SettingsKey {
  final String group, short, title;
  final String? knob, detail, engine;
  final List<int>? led; // config_voice(engine, r, g, b)
  final bool uncertain, danger;

  /// A switch the app may press over USB (StcK): MIDI modes, tunings, settings presets, voices,
  /// Panic. Dial keys (sensitivities, volume...) are set from the app's own controls instead, and
  /// the firmware refuses Reset and Send cfg.
  final bool switchable;
  const SettingsKey(
    this.group,
    this.short,
    this.title, {
    this.knob,
    this.detail,
    this.engine,
    this.led,
    this.uncertain = false,
    this.danger = false,
    this.switchable = false,
  });

  /// The full description: title (and '?'), the knob, the detail, the key.
  List<String> describe(int id) => ['$title${uncertain ? ' (?)' : ''}', if (knob != null) 'tilt or circle the key: $knob', ?detail, 'key $id'];
}

// the factory tunings 0-8 (config.h fT<n>..., as on the settings card: tuning.dart); the
// configuration editor can change them, which only the N command reports, so the details say so
final List<String> cardTunings = [for (final t in factoryTunings) t.name];
final List<String> cardTuningsShort = [for (final t in factoryTunings) t.short];

/// The button id of each tuning key, by tuning index 0..8 (row 5 in config_but).
const List<int> tuningKeyIds = [34, 36, 38, 23, 25, 27, 29, 31, 33];

/// Engine and indicator led colour per voice key, as config_voice(engine, r, g, b).
const Map<int, (String, List<int>)> voiceKeys = {
  18: ('strisy', [40, 40, 40]),
  20: ('va', [64, 20, 0]),
  22: ('modal', [0, 24, 64]),
  24: ('bowed', [64, 0, 0]),
  26: ('wind', [0, 64, 0]),
  28: ('ep', [40, 0, 64]),
  13: ('brass', [64, 40, 0]),
  15: ('trumpet', [0, 48, 48]),
};

/// Voice keys of engines newer than some firmware still in use: a firmware without the engine
/// has no case for the key (the overlay then shows the key as missing from this firmware).
const Set<int> newerVoiceKeys = {15};

final Map<int, SettingsKey> settingsKeys = {
  0: const SettingsKey(SettingsGroup.midi, 'MPE', 'MPE MIDI mode', knob: 'number of MPE voices, 1 to 15', switchable: true),
  2: const SettingsKey(SettingsGroup.midi, 'Poly', 'Normal MIDI mode (all notes on one channel)', knob: 'MIDI channel, 1 to 16', switchable: true),
  4: const SettingsKey(SettingsGroup.midi, 'Mono', 'Mono (glissando) MIDI mode', knob: 'MIDI channel, 1 to 16', switchable: true),
  11: const SettingsKey(SettingsGroup.layout, 'Flip', 'Flip the layout 180°', detail: 'With the glissando button also held: debug mode on/off.'),
  17: const SettingsKey(SettingsGroup.sens, 'Thres', 'Note-on threshold', knob: 'how light a touch starts a note (led dial 0 to 15)'),
  19: const SettingsKey(SettingsGroup.sens, 'Press', 'Pressure sensitivity', knob: '0 to 3, steps of 1/8'),
  21: const SettingsKey(SettingsGroup.sens, 'Velo', 'Velocity sensitivity', knob: '0 to 2, steps of 1/8'),
  6: const SettingsKey(SettingsGroup.sens, 'Bend', 'Pitch bend sensitivity (sideways tilt)', knob: '0 to 4, steps of 1/4'),
  8: const SettingsKey(SettingsGroup.sens, 'Tilt', 'Tilt (forward/back) sensitivity', knob: '0 to 3, steps of 1/8'),
  for (final e in voiceKeys.entries)
    e.key: SettingsKey(
      SettingsGroup.voice,
      e.value.$1,
      'Voice: ${e.value.$1}',
      engine: e.value.$1,
      led: e.value.$2,
      knob: 'step through its presets (the up/down leds show which)',
      detail: 'A press selects the engine with the preset it had last (remembered while powered).',
      switchable: true,
    ),
  for (final (n, id) in tuningKeyIds.indexed)
    id: SettingsKey(
      SettingsGroup.tuning,
      cardTuningsShort[n],
      'Tuning $n: ${cardTunings[n]}',
      knob: 'fine tuning offset, 1/32 semitone per step',
      detail: n == 0 ? null : 'Factory tuning; the configuration editor can change it.',
      switchable: true,
    ),
  for (final (n, id) in presetKeyIds.indexed)
    id: SettingsKey(
      SettingsGroup.preset,
      'P${n + 1}',
      'Load settings preset ${n + 1}',
      detail: n == 0
          ? 'Save to Striso stores the touch settings in preset 1, which the board loads at power-on.'
          : 'Loads the stored settings of this preset (sensitivities, MIDI, colour).',
      switchable: true,
    ),
  51: const SettingsKey(SettingsGroup.midi2, 'Vol', 'Volume (MIDI CC7)', knob: 'volume, 0 to 127'),
  53: const SettingsKey(SettingsGroup.midi2, 'Sust', 'Sustain / decay (pedal)', knob: 'release length, 0 to 1'),
  56: const SettingsKey(SettingsGroup.midi2, 'MPEbd', 'MPE pitch bend range', knob: '12, 24, 48 or 96 semitones'),
  58: const SettingsKey(SettingsGroup.midi2, 'Rate', 'MIDI message interval', knob: '1 to 15 ms'),
  63: const SettingsKey(SettingsGroup.system, 'Panic', 'Panic: all MIDI notes off', switchable: true),
  65: const SettingsKey(SettingsGroup.system, 'Cfg', 'Send the MPE and pitch bend configuration over MIDI'),
  67: const SettingsKey(SettingsGroup.system, 'Reset', 'System reset: restarts the Striso', danger: true),
};

/// The settings preset keys (P1..P8) by preset index, as config_but has them.
const List<int> presetKeyIds = [35, 37, 39, 41, 43, 45, 30, 32];

/// The control buttons with Settings held (synth_control.cpp IDC_OCT_UP/DOWN with altmode).
const Map<int, String> settingsControls = {
  1: 'With Settings: transpose a semitone up',
  2: 'With Settings: transpose a semitone down',
  3: 'Settings: hold it and press a key',
};
const String settingsBothOctaves = 'Both octave buttons with Settings: reset the transposition (without Settings: free transpose).';

/// One click on a voice key: on another engine, select it with its remembered preset (like a press
/// on the Striso); on the current engine, the next preset (the Striso steps with a tilt and stops at
/// the ends; a click wraps around).
({int index, String name, int presetIndex, int count})? voiceKeyAction(
  List<VoiceEntry> voices,
  int current,
  String engine, [
  Map<String, int> remembered = const {},
  int dir = 1,
]) {
  final list = voices.where((v) => v.engine == engine).toList();
  if (list.isEmpty) return null;
  final at = list.indexWhere((v) => v.index == current);
  final idx = at < 0 ? (remembered[engine] ?? 0).clamp(0, list.length - 1) : (at + dir + list.length) % list.length;
  return (index: list[idx].index, name: list[idx].name, presetIndex: idx, count: list.length);
}

/// The led colour at full brightness, 0xRRGGBB.
int ledColor(List<int> rgb) {
  final m = rgb.reduce((a, b) => a > b ? a : b);
  final s = m < 1 ? 1 : m;
  int c(int v) => (v / s * 255).round();
  return (c(rgb[0]) << 16) | (c(rgb[1]) << 8) | c(rgb[2]);
}
