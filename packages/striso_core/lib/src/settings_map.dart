// The settings mode (the Settings button held) as the overlay draws it. What every key does comes
// from the board itself (StcX: board_state.dart); this file only has the overlay's words for
// the groups, their rim colours, and the how-to lines. Keys are button ids, as the key stream's.

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

  /// 'switch', 'dial' or 'action' (StcX).
  final String kind;

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
    this.kind = 'switch',
  });

  /// The settings card's tuning this key loads (0..8), from its title ("Tuning 2: 19-TET"), or -1.
  int get tuningIndex {
    if (group != SettingsGroup.tuning) return -1;
    final m = RegExp(r'^Tuning (\d+)').firstMatch(title);
    return m == null ? -1 : int.parse(m.group(1)!);
  }

  /// The full description: title (and '?'), the knob, the detail, the key.
  List<String> describe(int id) => ['$title${uncertain ? ' (?)' : ''}', if (knob != null) 'tilt or circle the key: $knob', ?detail, 'key $id'];
}

/// The control buttons with Settings held (synth_control.cpp IDC_OCT_UP/DOWN with altmode).
const Map<int, String> settingsControls = {
  1: 'With Settings: transpose a semitone up',
  2: 'With Settings: transpose a semitone down',
  3: 'Settings: hold it and press a key',
};
const String settingsBothOctaves = 'Both octave buttons with Settings: reset the transposition (without Settings: free transpose).';

/// The led colour at full brightness, 0xRRGGBB.
int ledColor(List<int> rgb) {
  final m = rgb.reduce((a, b) => a > b ? a : b);
  final s = m < 1 ? 1 : m;
  int c(int v) => (v / s * 255).round();
  return (c(rgb[0]) << 16) | (c(rgb[1]) << 8) | c(rgb[2]);
}
