// What the board reports about itself, read-only (the firmware is the source of truth; the app
// keeps no model of its own): the settings-key layout (StcX) and the state in one line (StcY)
// with its change counter (Stcy). Formats: the firmware's synth_control.cpp
// (synth_settings_keys_print, synth_state_print).

import 'settings_map.dart';

/// One StcX line: `X <id> <kind> <group> <engine|-> <led|-> <flags|-> <short>|<title>|<knob>`.
final _xLine = RegExp(r'^X (\d+) (switch|dial|action) (\w+) (\S+) (\S+) (\S+) ([^|]*)\|([^|]*)\|(.*)$');
final _xHead = RegExp(r'^X keys (\d+)$');

/// The firmware's group words, as the overlay names them.
const Map<String, String> settingsGroupOf = {
  'midi': SettingsGroup.midi,
  'layout': SettingsGroup.layout,
  'sens': SettingsGroup.sens,
  'voice': SettingsGroup.voice,
  'tuning': SettingsGroup.tuning,
  'preset': SettingsGroup.preset,
  'midi2': SettingsGroup.midi2,
  'system': SettingsGroup.system,
};

/// The settings-key layout as the board lists it: key id -> what it does with Settings held.
class SettingsLayout {
  final Map<int, SettingsKey> keys;
  const SettingsLayout(this.keys);

  static const empty = SettingsLayout({});
  bool get isEmpty => keys.isEmpty;
  SettingsKey? operator [](int id) => keys[id];

  /// The voice key of [engine] (StcK presses it like the instrument does), or null.
  int? voiceKeyOf(String engine) {
    for (final e in keys.entries) {
      if (e.value.engine == engine) return e.key;
    }
    return null;
  }

  /// Voice keys in key order: (key id, engine, led rgb).
  List<(int, String, List<int>)> get voiceKeys => [
    for (final e in keys.entries)
      if (e.value.engine != null) (e.key, e.value.engine!, e.value.led ?? const [255, 255, 255]),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
}

/// The StcX reply (its lines, "X keys n" .. "X end"); null when it is not one.
SettingsLayout? parseSettingsLayout(List<String> lines) {
  int? n;
  final keys = <int, SettingsKey>{};
  var ended = false;
  for (final raw in lines) {
    final l = raw.trim();
    final h = _xHead.firstMatch(l);
    if (h != null) {
      n = int.parse(h.group(1)!);
      continue;
    }
    if (l == 'X end') {
      ended = true;
      break;
    }
    final m = _xLine.firstMatch(l);
    if (m == null) continue;
    final id = int.parse(m.group(1)!);
    final kind = m.group(2)!;
    final group = settingsGroupOf[m.group(3)!] ?? m.group(3)!;
    final engine = m.group(4)! == '-' ? null : m.group(4)!;
    final ledHex = m.group(5)!;
    final flags = m.group(6)! == '-' ? '' : m.group(6)!;
    List<int>? led;
    if (ledHex != '-' && ledHex.length == 6) {
      final v = int.tryParse(ledHex, radix: 16);
      if (v != null) led = [(v >> 16) & 255, (v >> 8) & 255, v & 255];
    }
    final knob = m.group(9)!.trim();
    keys[id] = SettingsKey(
      group,
      m.group(7)!.trim(),
      m.group(8)!.trim(),
      knob: knob.isEmpty ? null : knob,
      engine: engine,
      led: led,
      danger: flags.contains('d'),
      switchable: flags.contains('k'),
      kind: kind,
    );
  }
  if (n == null || !ended) return null;
  return SettingsLayout(keys);
}

/// The StcY line: the board's state now.
class BoardState {
  final int counter;
  final Map<String, String> fields;
  const BoardState(this.counter, this.fields);

  int? _int(String k) => int.tryParse(fields[k] ?? '');
  double? _num(String k) => double.tryParse(fields[k] ?? '');

  int? get voice => _int('voice');

  /// 'mpe', 'poly' or 'mono'.
  String? get midi => fields['midi'];
  int? get channel => _int('ch');
  int? get voices => _int('voices');
  int? get bend => _int('bend');

  /// The settings card's tuning (0..8), -1 after a MIDI fifth.
  int? get tuning => _int('tuning');
  double? get fineCents => _num('fine');

  /// The transposition in semitones (a semitone of a non-12 tuning is not 1.0).
  double? get transpose => _num('transpose');
  double? get pres => _num('pres');
  double? get velo => _num('velo');
  double? get tilt => _num('tilt');
  double? get bendSens => _num('bendsens');
  double? get threshold => _num('thres');
  int? get volume => _int('vol');
  double? get sustain => _num('sustain');
  int? get rate => _int('rate');
  bool get settingsHeld => fields['alt'] == '1';
  bool get portamento => fields['porta'] == '1';
  bool get flipped => fields['flip'] == '1';

  /// The indicator led, 0xRRGGBB.
  int? get led => int.tryParse(fields['led'] ?? '', radix: 16);

  /// up2, up, down, down2: 0 off, 1 dim, 2 on.
  List<int> get updown => [for (final c in (fields['updown'] ?? '').split('')) int.tryParse(c) ?? 0];

  @override
  String toString() => 'BoardState($counter, $fields)';
}

final _yLine = RegExp(r'^Y (\d+)((?: \w+=\S*)*)\s*$');
final _yCount = RegExp(r'^y (\d+)\s*$');

BoardState? parseBoardState(String line) {
  final m = _yLine.firstMatch(line.trim());
  if (m == null) return null;
  final f = <String, String>{};
  for (final kv in m.group(2)!.trim().split(' ')) {
    final i = kv.indexOf('=');
    if (i > 0) f[kv.substring(0, i)] = kv.substring(i + 1);
  }
  return BoardState(int.parse(m.group(1)!), f);
}

int? parseChangeCount(String line) {
  final m = _yCount.firstMatch(line.trim());
  return m == null ? null : int.parse(m.group(1)!);
}
