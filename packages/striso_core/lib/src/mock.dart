// A simulated Striso for development, demos and tests: the console commands of pconnection.c,
// voices with live parameters, touch settings and key factors, synth load, and a performer that
// plays the keys and moves the motion sensor. Output is interleaved and chunked like the real bulk
// endpoint: text can be split by binary messages and by 64 byte packets anywhere.
// Port of tools/app/js/mock.js.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'layout.dart';
import 'protocol.dart';
import 'settings_map.dart';
import 'transport.dart';
import 'tuning.dart';

typedef _P = (String name, String group, double min, double max, int kind, double def);

const List<_P> _va = [
  ('gain', 'level', 0.5, 5.0, 0, 2.3),
  ('pres_lin', 'level', 0.0, 1.0, 0, 0.3),
  ('pres_sq', 'level', 0.0, 1.5, 0, 0.7),
  ('pres_hz', 'level', 1.0, 200.0, 0, 70.0),
  ('hold_decay', 'level', 0.005, 1.0, 0, 0.045),
  ('release', 'release', 0.02, 4.0, 0, 0.1),
  ('rel_pedal', 'release', 0.0, 6.0, 0, 2.9),
  ('rel_speed', 'release', 0.0, 8.0, 0, 3.0),
  ('acc_level', 'accent', 0.0, 2.5, 0, 0.75),
  ('acc_decay', 'accent', 0.005, 0.4, 0, 0.04),
  ('acc_key', 'accent', 0.0, 0.06, 0, 0.02778),
  ('acc_cutoff', 'accent', 0.0, 48.0, 0, 28.0),
  ('acc_drive', 'accent', 0.0, 2.0, 0, 0.7),
  ('acc_sync', 'accent', 0.0, 24.0, 0, 10.0),
  ('acc_pitch', 'accent', -1.0, 1.0, 0, 0.0),
  ('cut_base', 'filter', -20.0, 80.0, 0, 26.0),
  ('cut_key', 'filter', 0.0, 1.2, 0, 0.75),
  ('cut_env', 'filter', 0.0, 80.0, 0, 46.0),
  ('cut_back', 'filter', -24.0, 24.0, 0, 9.0),
  ('cut_fwd', 'filter', -24.0, 24.0, 0, 5.0),
  ('res', 'filter', 0.0, 0.98, 0, 0.2),
  ('res_back', 'filter', -0.5, 0.98, 0, 0.72),
  ('res_fwd', 'filter', -0.5, 0.98, 0, 0.08),
  ('bass_comp', 'filter', 0.0, 1.0, 0, 0.45),
  ('drive', 'filter', 0.1, 3.0, 0, 0.6),
  ('drive_env', 'filter', 0.0, 3.0, 0, 0.9),
  ('saw', 'osc', 0.0, 1.0, 0, 0.5),
  ('saw_back', 'osc', 0.0, 1.0, 0, 0.75),
  ('saw_fwd', 'osc', 0.0, 1.0, 0, 0.65),
  ('saw2', 'osc', 0.0, 1.0, 0, 0.36),
  ('saw2_back', 'osc', 0.0, 1.0, 0, 0.5),
  ('saw2_fwd', 'osc', 0.0, 1.0, 0, 0.6),
  ('saw2_detune', 'osc', -0.5, 0.5, 0, 0.07),
  ('pulse', 'osc', 0.0, 1.0, 0, 0.0),
  ('pulse_back', 'osc', 0.0, 1.0, 0, 0.45),
  ('pwm', 'osc', 0.0, 0.4, 0, 0.13),
  ('pwm_hz', 'osc', 0.05, 8.0, 0, 0.37),
  ('sub', 'osc', 0.0, 1.0, 0, 0.5),
  ('sub_base', 'osc', 0.0, 1.0, 0, 0.2),
  ('sub_back', 'osc', 0.0, 1.0, 0, 0.25),
  ('sub_fwd', 'osc', 0.0, 1.0, 0, 0.6),
  ('b_sync', 'osc', 0.0, 1.0, 2, 1.0),
  ('b_level', 'osc', 0.0, 1.0, 0, 0.0),
  ('b_fwd', 'osc', 0.0, 1.0, 0, 0.5),
  ('b_detune', 'osc', -0.5, 0.5, 0, 0.0),
  ('sync', 'osc', 0.0, 24.0, 0, 5.0),
  ('sync_fwd', 'osc', 0.0, 24.0, 0, 12.0),
  ('sync_env', 'osc', 0.0, 24.0, 0, 9.0),
  ('tilt_home', 'osc', -1.0, 1.0, 0, 0.0),
  ('drift', 'mod', 0.0, 0.3, 0, 0.03),
  ('saw2_drift', 'mod', 0.0, 0.3, 0, 0.025),
  ('cut_drift', 'mod', 0.0, 2.0, 0, 0.3),
  ('gyro_chorus', 'mod', 0.0, 1.0, 0, 0.22),
  ('vibrato', 'mod', 0.0, 1.5, 0, 0.35),
  ('vib_hz', 'mod', 1.0, 9.0, 0, 5.3),
];
const List<_P> _modal = [
  ('level', 'level', 0.1, 3.0, 0, 1.2),
  ('thresh', 'mallet', 0.005, 0.2, 0, 0.04),
  ('span', 'mallet', 0.2, 1.5, 0, 0.6),
  ('hard', 'mallet', 0.2, 1.2, 0, 0.7),
  ('hardvel', 'mallet', 0.0, 1.0, 0, 0.5),
  ('tilt', 'mallet', 0.0, 0.5, 0, 0.2),
  ('mute', 'mallet', 0.0, 1.0, 0, 0.3),
  ('upper', 'tone', 0.0, 2.0, 0, 1.0),
  ('decay', 'decay', 0.1, 4.0, 0, 1.0),
  ('keytrack', 'decay', 0.0, 1.5, 0, 0.8),
  ('hfdamp', 'decay', 0.0, 1.0, 0, 0.4),
  ('damper', 'damper', 0.0, 2.0, 0, 1.0),
  ('lift', 'damper', 0.02, 0.5, 0, 0.12),
  ('pedal', 'damper', 0.0, 1.0, 0, 0.0),
  ('trem', 'trem', 0.0, 1.0, 2, 0),
  ('tremrate', 'trem', 1.0, 10.0, 0, 5.5),
  ('tremdepth', 'trem', 0.0, 1.0, 0, 0.4),
  ('tremthr', 'trem', 0.2, 1.2, 0, 0.6),
  ('rub', 'rub', 0.0, 1.0, 0, 0.3),
  ('rubnoise', 'rub', 0.0, 0.3, 0, 0.05),
];
const List<_P> _bowed = [
  ('level', 'level', 0.1, 4.0, 0, 1.5),
  ('bow_force', 'bow', 0.0, 1.0, 0, 0.45),
  ('bow_speed', 'bow', 0.0, 1.0, 0, 0.6),
  ('bow_pos', 'bow', 0.02, 0.5, 0, 0.12),
  ('rosin', 'bow', 0.0, 1.0, 0, 0.5),
  ('body', 'body', 0.0, 1.0, 0, 0.6),
  ('body_size', 'body', 0.5, 2.0, 0, 1.0),
  ('damping', 'string', 0.0, 1.0, 0, 0.3),
  ('inharm', 'string', 0.0, 0.2, 0, 0.02),
  ('vibrato', 'mod', 0.0, 1.0, 0, 0.3),
  ('vib_hz', 'mod', 3.0, 8.0, 0, 5.4),
];
const List<_P> _reed = [
  ('level', 'level', 0.1, 4.0, 0, 1.4),
  ('breath', 'breath', 0.0, 1.0, 0, 0.5),
  ('noise', 'breath', 0.0, 0.5, 0, 0.08),
  ('stiffness', 'reed', 0.0, 1.0, 0, 0.55),
  ('aperture', 'reed', 0.0, 1.0, 0, 0.4),
  ('bore', 'tube', 0, 3, 1, 1),
  ('bell', 'tube', 0.0, 1.0, 0, 0.5),
  ('growl', 'mod', 0.0, 1.0, 0, 0.0),
  ('vibrato', 'mod', 0.0, 1.0, 0, 0.25),
];
const List<_P> _ep = [
  ('level', 'level', 0.1, 4.0, 0, 1.6),
  ('hammer', 'hammer', 0.0, 1.0, 0, 0.5),
  ('hardness', 'hammer', 0.0, 1.0, 0, 0.45),
  ('tine', 'tone', 0.0, 1.0, 0, 0.6),
  ('bark', 'tone', 0.0, 1.0, 0, 0.3),
  ('pickup', 'tone', -1.0, 1.0, 0, 0.1),
  ('decay', 'decay', 0.2, 8.0, 0, 3.0),
  ('release', 'decay', 0.02, 2.0, 0, 0.25),
  ('trem_on', 'trem', 0, 1, 2, 1),
  ('trem_rate', 'trem', 0.5, 9.0, 0, 4.2),
  ('trem_depth', 'trem', 0.0, 1.0, 0, 0.35),
  ('voicing', 'trem', 0, 4, 1, 2),
];
const List<_P> _fx = [
  ('chorus', 'chorus', 0, 1, 2, 1),
  ('ch_rate', 'chorus', 0.05, 5.0, 0, 0.6),
  ('ch_depth', 'chorus', 0.0, 1.0, 0, 0.35),
  ('ch_mix', 'chorus', 0.0, 1.0, 0, 0.3),
  ('delay', 'delay', 0, 1, 2, 0),
  ('dl_time', 'delay', 0.02, 1.5, 0, 0.38),
  ('dl_sync', 'delay', 0, 7, 1, 3),
  ('dl_fb', 'delay', 0.0, 0.95, 0, 0.35),
  ('dl_mix', 'delay', 0.0, 1.0, 0, 0.2),
  ('dl_pong', 'delay', 0, 1, 2, 1),
  ('reverb', 'reverb', 0, 1, 2, 1),
  ('rv_size', 'reverb', 0.0, 1.0, 0, 0.55),
  ('rv_damp', 'reverb', 0.0, 1.0, 0, 0.4),
  ('rv_mix', 'reverb', 0.0, 1.0, 0, 0.22),
  ('trem', 'tremolo', 0, 1, 2, 0),
  ('tr_rate', 'tremolo', 0.1, 12.0, 0, 4.0),
  ('tr_depth', 'tremolo', 0.0, 1.0, 0, 0.4),
  ('tr_pan', 'tremolo', 0, 1, 2, 1),
  ('width', 'master', 0.0, 2.0, 0, 1.0),
  ('gain', 'master', 0.0, 2.0, 0, 1.0),
];

/// Global touch settings (console 'g', target 2), as synth_control.cpp.
const List<_P> _touch = [
  ('pressure', 'touch', 0.1, 4.0, 0, 1.0),
  ('velocity', 'touch', 0.1, 4.0, 0, 1.0),
  ('tilt', 'touch', -4.0, 4.0, 0, 1.0),
  ('bend', 'touch', 0.0, 8.0, 0, 0.5),
  ('threshold', 'touch', 0.0, 0.5, 0, 0.0),
];

class _Engine {
  final String engine;
  final List<String>? presets;
  final List<_P> params;
  final double cost;
  const _Engine(this.engine, this.presets, this.params, this.cost);
}

/// The engines and presets of the current firmware (synth_strisy.cpp VOICE_LIST, voice_*.h names).
const List<_Engine> _engines = [
  _Engine('strisy', null, [], 6200),
  _Engine('va', ['classic', 'pad', 'lead', 'bass', 'brass', 'keys', 'acid', 'strings'], _va, 9800),
  _Engine('modal', ['vibraphone', 'marimba', 'glockenspiel', 'bell', 'kalimba', 'wine glass'], _modal, 12500),
  _Engine('bowed', ['violin', 'viola', 'cello', 'bass', 'section', 'ponticello', 'flautando', 'sordino', 'pizzicato'], _bowed, 11000),
  _Engine('wind', ['clarinet', 'bass clarinet', 'soprano sax', 'alto sax', 'tenor sax', 'baritone sax', 'oboe', 'bassoon', 'flute'], _reed, 8600),
  _Engine(
    'ep',
    ['stage', 'suitcase', 'mk2', 'dyno', 'ballad', 'bark', 'neosoul', 'fm80s', 'lofi', 'wurli', 'wurlibark', 'pianet', 'felt', 'celesta'],
    _ep,
    7600,
  ),
  _Engine('brass', ['trumpet', 'flugelhorn', 'trombone', 'horn', 'euphonium', 'tuba', 'harmon', 'plunger', 'section'], _reed, 9000),
];

class _Entry {
  final String engine;
  final String? preset;
  final _Engine eng;
  final int seed;
  const _Entry(this.engine, this.preset, this.eng, this.seed);
  String get name => preset != null ? '$engine:$preset' : engine;
}

/// Deterministic generator, so presets differ but stay stable (same as the JS LCG).
double Function() lcg(int seed) {
  var s = seed & 0xffffffff;
  if (s == 0) s = 1;
  return () {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return s / 4294967296;
  };
}

List<double> _presetValues(List<_P> table, int seed) {
  final r = lcg(seed);
  return [
    for (final p in table)
      if (seed == 0)
        p.$6
      else
        conformTo(p.$3, p.$4, p.$5, p.$5 == Kind.onOff ? (r() < 0.7 ? p.$6 : 1 - p.$6) : p.$6 + (r() - 0.5) * 0.5 * (p.$4 - p.$3), p.$6),
  ];
}

const _budget = 314572; // 480 MHz * 32 / 48828
const _blocksPerSecond = 48828 / 32;

class _Key {
  double pres = 0, vpres = 0, x = 0, y = 0;
  bool manual = false;
}

/// Saved touch settings and key factors (what the simulated board loads at boot).
class MockConfig {
  final List<double> touch, keys;
  const MockConfig(this.touch, this.keys);
}

class MockBoard {
  final String firmware;
  final _entries = <_Entry>[];
  late int voice;
  late List<double> values;
  final List<double> fx = [for (final p in _fx) p.$6];
  late final List<double> touch;
  late final List<double> keyFactors;
  late final Float32List gain;

  // the tuning, as Instrument in synth_control.cpp holds it (semitones)
  int tuning = 0;
  double notegen0 = 12, notegen1 = 7, noteOffset = 0;
  int tuningColor = 0x00aa00;
  final keyOffset = Float64List(61);
  MockConfig? _config;
  bool streaming = false;
  bool autoplay, motionEnabled;
  int idleFrames;
  Duration listDelay;
  final math.Random random;
  void Function(Uint8List bytes)? _listener;
  final _text = <int>[];
  final _msgs = <Uint8List>[];
  int _rxNeed = 0, _rxState = 0;
  String _rxCmd = 'Q';
  final _rxPayload = <int>[];

  /// MIDI mode as the settings keys set it: 'mpe', 'poly' or 'mono'; the loaded settings preset.
  String midiMode = 'mpe';
  int settingsPreset = 1;
  final remembered = <String, int>{};
  int _loadBlocks = 0, _loadPeak = 0;
  double _loadSum = 0;
  final keys = <int, _Key>{};
  final controlsDown = Uint8List(4);
  late final _Performer _performer;
  double t = 0;
  final _clock = Stopwatch()..start();
  int _lastTickUs = 0;
  double _motionAcc = 0, _idleAcc = 0;
  Timer? _timer;

  MockBoard({
    this.autoplay = true,
    this.motionEnabled = true,
    this.idleFrames = 500,
    MockConfig? config,
    this.listDelay = Duration.zero,
    this.firmware = 'striso_control_strisoboard_v2.2.4-voices-mock',
    math.Random? random,
  }) : random = random ?? math.Random() {
    for (var k = 0; k < _engines.length; k++) {
      final e = _engines[k];
      if (e.presets == null) {
        _entries.add(_Entry(e.engine, null, e, k * 100));
      } else {
        for (var j = 0; j < e.presets!.length; j++) {
          _entries.add(_Entry(e.engine, e.presets![j], e, j == 0 ? 0 : k * 100 + j));
        }
      }
    }
    voice = _entries.indexWhere((e) => e.engine == 'va'); // DEFAULT_ENGINE = va
    values = _presetValues(_entries[voice].eng.params, _entries[voice].seed);
    _config = config;
    touch = config != null ? [...config.touch] : [for (final p in _touch) p.$6];
    keyFactors = config != null ? [...config.keys] : List<double>.filled(61, 1);
    final g = lcg(4242);
    gain = Float32List.fromList([for (var i = 0; i < 68; i++) 0.7 + 0.65 * g()]);
    _performer = _Performer(this);
  }

  int get voiceCount => _entries.length;
  String voiceName(int n) => _entries[n].name;

  // transport side -------------------------------------------------------------------------------

  void attach(void Function(Uint8List bytes) listener) {
    _listener = listener;
    _lastTickUs = _clock.elapsedMicroseconds;
    _timer ??= Timer.periodic(const Duration(milliseconds: 4), (_) => tick());
  }

  void detach() {
    _listener = null;
    _timer?.cancel();
    _timer = null;
  }

  void receive(List<int> bytes) {
    for (final b in bytes) {
      _receiveByte(b);
    }
  }

  // pconnection.c PExReceiveByte
  void _receiveByte(int c) {
    if (_rxNeed > 0) {
      _rxPayload.add(c);
      if (--_rxNeed == 0) {
        final p = _rxPayload;
        if (_rxCmd == 'K') {
          _print(settingsKey(p[0]) ? 'K ok ${p[0]}\r\n' : 'K err ${p[0]}\r\n');
        } else {
          final v = ByteData.sublistView(Uint8List.fromList(p.sublist(2, 6))).getFloat32(0, Endian.little);
          if (!setParam(p[0], p[1], v)) _print('Q err ${p[0]} ${p[1]}\r\n');
        }
      }
      return;
    }
    if (_rxState == 0) {
      if (c == 0x53) _rxState = 1;
      return;
    }
    if (_rxState == 1) {
      _rxState = c == 0x74 ? 2 : 0;
      return;
    }
    if (_rxState == 2) {
      _rxState = c == 0x63 ? 3 : 0;
      return;
    }
    _rxState = 0;
    _command(c);
  }

  void _command(int c) {
    final ch = String.fromCharCode(c);
    if (ch == 'S') {
      streaming = true;
    } else if (ch == 's') {
      streaming = false;
      _print('Stcs\r\n');
    } else if (ch == 'V') {
      streaming = false;
      _text.clear();
      _msgs.clear();
      _print('$firmware 0043002B3132510A33383339 STRISO-MOCK\r\nCalibration date: 2024-03-11\r\n');
    } else if (ch == 'L') {
      _print('synth blocks $_loadBlocks avg ${_loadBlocks > 0 ? (_loadSum / _loadBlocks).floor() : 0} peak $_loadPeak budget $_budget cycles\r\n');
      _loadSum = 0;
      _loadPeak = 0;
      _loadBlocks = 0;
    } else if (ch == 'v') {
      for (var n = 0; n < _entries.length; n++) {
        _print('${n == voice ? '*' : ' '} $n ${_entries[n].name}\r\n');
      }
    } else if (c >= 0x80) {
      final n = c - 0x80;
      if (n < _entries.length) {
        voice = n;
        values = _presetValues(_entries[n].eng.params, _entries[n].seed);
        _print('voice $n ${_entries[n].name}\r\n');
      } else {
        _print('no voice $n\r\n');
      }
    } else if ('pfgk'.contains(ch)) {
      final target = 'pfgk'.indexOf(ch);
      if (listDelay > Duration.zero) {
        Timer(listDelay, () => _printParams(target));
      } else {
        _printParams(target);
      }
    } else if (ch == 'Q') {
      _rxNeed = 6;
      _rxCmd = 'Q';
      _rxPayload.clear();
    } else if (ch == 'K') {
      _rxNeed = 1;
      _rxCmd = 'K';
      _rxPayload.clear();
    } else if (ch == 'N') {
      _printTuning();
    } else if (ch == 'I') {
      _print('stklimit    stack     addr   unused refs prio     state         name\r\n(mock device)\r\n');
    } else if (ch == 'P') {
      _print('profile over 1500 blocks, voice ${_entries[voice].name}, mock\r\n');
    }
  }

  void _printParams(int target) {
    final sb = StringBuffer();
    if (target == Target.keys) {
      sb.write('params 3 keys 61\r\n');
      for (var n = 0; n < 61; n++) {
        sb.write('$n ${firmwareKeyName(n)} keys ${floatToHex(0.1)} ${floatToHex(10)} ${floatToHex(keyFactors[n])} 0\r\n');
      }
    } else {
      final table = target == 0
          ? _entries[voice].eng.params
          : target == 1
          ? _fx
          : _touch;
      final vals = target == 0
          ? values
          : target == 1
          ? fx
          : touch;
      final name = target == 0
          ? _entries[voice].name
          : target == 1
          ? 'fx'
          : 'touch';
      sb.write('params $target $name ${table.length}\r\n');
      for (var i = 0; i < table.length; i++) {
        final p = table[i];
        sb.write('$i ${p.$1} ${p.$2} ${floatToHex(p.$3)} ${floatToHex(p.$4)} ${floatToHex(vals[i])} ${p.$5}\r\n');
      }
    }
    _print(sb.toString());
  }

  // the N reply: the tuning and what every key plays (see tuning.dart for the format)
  void _printTuning() {
    final sb = StringBuffer()
      ..write('tuning $tuning ${floatToHex(notegen1)} ${floatToHex(notegen0)} ${floatToHex(noteOffset)} ')
      ..write('${tuningColor.toRadixString(16).padLeft(6, '0')} ${floatToHex(startNote.toDouble())} 61\r\n');
    for (var n = 0; n < 61; n++) {
      sb.write('$n ${firmwareKeyName(n)} ${floatToHex(keyPitch(buttonNumberMap[n]))} ${floatToHex(keyOffset[n])}\r\n');
    }
    _print(sb.toString());
  }

  /// What button [id] plays, MIDI-like semitones (Button::note).
  double keyPitch(int id) {
    final n = keyNumberOf[id];
    return startNote + noteOffset + notegen0 * c0[id] + notegen1 * c1[id] + (n == null ? 0 : keyOffset[n]);
  }

  /// load_tuning(n): the settings card's tunings 0..8 (the fine tune is kept, as the board does).
  void loadTuning(int n) {
    final t = factoryTunings[n.clamp(0, factoryTunings.length - 1)];
    tuning = t.index;
    notegen1 = toFloat32(t.fifth / 100);
    notegen0 = toFloat32(t.octave / 100);
    tuningColor = t.color;
    for (var k = 0; k < 61; k++) {
      keyOffset[k] = toFloat32(factoryKeyOffset(t, k) / 100);
    }
  }

  /// The fine tune in cents (the knob on the tuning keys), e.g. -31.77 for A = 432 Hz.
  void fineTune(double cents) => noteOffset = toFloat32(cents / 100);

  /// StcK: a settings key pressed over USB (config_but with type 0). True when the key is one the
  /// board switches: MIDI modes, tunings, settings presets, voices, Panic; dials and system keys
  /// are refused.
  bool settingsKey(int id) {
    final f = settingsKeys[id];
    if (f == null || !f.switchable) return false;
    if (f.group == SettingsGroup.midi) {
      midiMode = const {0: 'mpe', 2: 'poly', 4: 'mono'}[id]!;
      return true;
    }
    if (f.group == SettingsGroup.tuning) {
      loadTuning(tuningKeyIds.indexOf(id));
      return true;
    }
    if (f.group == SettingsGroup.preset) {
      // a stored preset: the touch settings as saved (preset 1), the defaults for the others
      settingsPreset = presetKeyIds.indexOf(id) + 1;
      final saved = _config?.touch;
      for (var i = 0; i < _touch.length; i++) {
        touch[i] = settingsPreset == 1 && saved != null && i < saved.length ? saved[i] : _touch[i].$6;
      }
      return true;
    }
    if (f.engine != null) {
      // config_voice: the engine with the preset it had last
      final list = [for (var n = 0; n < _entries.length; n++) if (_entries[n].engine == f.engine) n];
      if (list.isEmpty) return false;
      if (list.contains(voice)) remembered[f.engine!] = list.indexOf(voice);
      final n = list[(remembered[f.engine!] ?? 0).clamp(0, list.length - 1)];
      if (n != voice) {
        voice = n;
        values = _presetValues(_entries[n].eng.params, _entries[n].seed);
      }
      return true;
    }
    return f.group == SettingsGroup.system && !f.danger && id == 63; // Panic
  }

  bool setParam(int target, int index, double v) {
    if (target == Target.touch) {
      if (index >= _touch.length || v.isNaN) return false;
      touch[index] = toFloat32(v.clamp(_touch[index].$3, _touch[index].$4)); // clamped, like synth_touch_set
      return true;
    }
    if (target == Target.keys) {
      if (index >= 61 || !(v >= 0.1 && v <= 10)) return false; // buttonSetKeyFactor
      keyFactors[index] = toFloat32(v);
      return true;
    }
    final table = target == 0
        ? _entries[voice].eng.params
        : target == 1
        ? _fx
        : null;
    if (table == null || index >= table.length || v.isNaN) return false;
    final p = table[index];
    (target == 0 ? values : fx)[index] = conformTo(p.$3, p.$4, p.$5, v, 0);
    return true;
  }

  void _print(String s) {
    for (final c in s.codeUnits) {
      _text.add(c & 0x7f);
    }
  }

  void _send(int src, int id, List<num> v) {
    if (streaming && _msgs.length < 4000) _msgs.add(encodeMessage(src, id, v));
  }

  // simulation -----------------------------------------------------------------------------------

  void tick() {
    final now = _clock.elapsedMicroseconds;
    final dt = math.min(0.05, (now - _lastTickUs) / 1e6);
    _lastTickUs = now;
    t += dt;
    if (autoplay) _performer.step(t);
    _sendKeys();
    if (idleFrames > 0) _sendIdle(dt);
    _motionAcc += dt;
    if (motionEnabled && _motionAcc >= 1 / 60) {
      _motionAcc %= 1 / 60;
      _sendMotion();
    }
    _simulateLoad(dt);
    _flush();
  }

  void _sendIdle(double dt) {
    _idleAcc += dt * idleFrames;
    while (_idleAcc >= 1) {
      _idleAcc--;
      final id = keyIds[random.nextInt(keyIds.length)];
      if (keys.containsKey(id)) continue;
      final noise = random.nextDouble() < 0.3 ? random.nextInt(8) : 0;
      _send(Src.dis, id, [
        noise,
        ((random.nextDouble() - 0.5) * 6).floor(),
        ((random.nextDouble() - 0.5) * 200).floor(),
        ((random.nextDouble() - 0.5) * 200).floor(),
      ]);
    }
  }

  void _sendKeys() {
    for (final id in keys.keys.toList()) {
      final k = keys[id]!;
      if (k.pres > 0) {
        // force x this key's hardware gain x its factor, saturated at full scale (firmware c9be783)
        final kn = keyNumberOf[id];
        final f = gain[id] * (kn == null ? 1 : keyFactors[kn]);
        _send(Src.dis, id, [
          _clampInt(k.pres * f * fullScale),
          _clampInt(k.vpres * f * fullScale),
          _clampInt(k.x * fullScale),
          _clampInt(k.y * fullScale),
        ]);
        k.vpres *= 0.6; // the velocity estimate settles while held
      } else {
        _send(Src.dis, id, [0, _clampInt(math.min(0.0, k.vpres) * fullScale), 0, 0]);
        keys.remove(id);
      }
    }
  }

  void _sendMotion() {
    final tx = 0.14 * math.sin(t * 0.37) + 0.05 * math.sin(t * 1.3);
    final ty = 0.1 * math.sin(t * 0.23 + 1) + 0.04 * math.sin(t * 0.9);
    final shake = _performer.shake * math.sin(t * 2 * math.pi * 5.5);
    final ax = tx + shake * 0.08, ay = ty, az = math.sqrt(math.max(0, 1 - tx * tx - ty * ty));
    final abs = math.sqrt(ax * ax + ay * ay + az * az);
    final gx = 0.37 * 0.14 * math.cos(t * 0.37) * 4000, gy = 0.23 * 0.1 * math.cos(t * 0.23 + 1) * 4000;
    _send(Src.accel, 8, [
      for (final v in [ax, ay, az, abs]) _clampInt(v * accPerG),
      _clampInt(gx),
      _clampInt(gy),
      _clampInt(shake * 900),
    ]);
  }

  void _simulateLoad(double dt) {
    final blocks = (dt * _blocksPerSecond).round();
    if (blocks == 0) return;
    var active = keys.values.where((k) => k.pres > 0).length + _performer.tails;
    final cost = _entries[voice].eng.cost;
    final avg = 26000 + math.min(10, active) * cost * (0.9 + 0.2 * random.nextDouble());
    _loadSum += avg * blocks;
    _loadBlocks += blocks;
    _loadPeak = math.max(_loadPeak, (avg * (1.08 + 0.15 * random.nextDouble())).round());
  }

  // interleave text and messages into one byte run, deliver it in packets of up to 64
  void _flush() {
    final l = _listener;
    if (l == null || (_text.isEmpty && _msgs.isEmpty)) return;
    final out = <int>[];
    var ti = 0, mi = 0;
    while (ti < _text.length || mi < _msgs.length) {
      if (ti < _text.length && (mi >= _msgs.length || random.nextDouble() < 0.5)) {
        final n = 1 + random.nextInt(24);
        for (var k = 0; k < n && ti < _text.length; k++) {
          out.add(_text[ti++]);
        }
      } else {
        out.addAll(_msgs[mi++]);
      }
    }
    _text.clear();
    _msgs.clear();
    for (var k = 0; k < out.length; k += Usb.packet) {
      final len = math.min(Usb.packet, out.length - k);
      // sometimes a short packet: the SOF flush sends partial buffers
      final cut = random.nextDouble() < 0.2 ? math.max(1, random.nextInt(len)) : len;
      l(Uint8List.fromList(out.sublist(k, k + cut)));
      if (cut < len) l(Uint8List.fromList(out.sublist(k + cut, k + len)));
    }
  }

  // manual playing (the board view in demo mode, tests) -------------------------------------------

  void press(int id, {double pres = 0.5, double x = 0, double y = 0, double strike = 0}) {
    final k = keys.putIfAbsent(id, _Key.new);
    k.vpres = math.max(strike, (pres - k.pres) * 3);
    k.pres = math.max(0.001, pres);
    k.x = x;
    k.y = y;
    k.manual = true;
  }

  void release(int id, [double lift = 0.3]) {
    final k = keys[id];
    if (k != null) {
      k.pres = 0;
      k.vpres = -lift;
    }
  }

  void control(int id, bool down) {
    controlsDown[id] = down ? 1 : 0;
    _send(Src.control, id, [down ? 1 : 0]);
  }
}

// chords as spelled notes (tpc on the line of fifths, C = 0), played from the bass upwards
const _tpc = {'C': 0, 'D': 2, 'E': 4, 'F': -1, 'G': 1, 'A': 3, 'B': 5, 'F#': 6, 'Ab': -4, 'Bb': -2, 'Eb': -3};
final List<List<int>> _progression = [
  'C E G',
  'A C E',
  'F A C',
  'G B D F',
  'C E G C',
  'D F A C',
  'G B D F',
  'C E G B',
  'E G C',
  'D F# A C',
  'G B D',
  'A C E G',
  'F A C D',
  'Ab C Eb',
  'G B D F',
  'C G C E',
].map((c) => c.split(' ').map((n) => _tpc[n]!).toList()).toList();

// keys for a chord: the bass near C3..C4, every next tone the nearest key above
List<int> _voiceChord(List<int> tpcs) {
  final out = <int>[];
  var floor = -15;
  for (final tpc in tpcs) {
    final cands = keyIds.where((id) => c1[id] + 2 == tpc && pitchOf(id) > floor).toList()..sort((a, b) => pitchOf(a) - pitchOf(b));
    if (cands.isEmpty) break;
    out.add(cands.first);
    floor = pitchOf(cands.first);
  }
  return out;
}

class _Note {
  final int id;
  final double t0, t1, peak, strike, vib, tilt, swell;
  _Note(this.id, this.t0, this.t1, this.peak, this.strike, this.vib, this.tilt, this.swell);
}

// plays phrases: chords, melodies, swells, vibrato and tilts
class _Performer {
  final MockBoard dev;
  var notes = <_Note>[];
  double next = 0.5, shake = 0;
  int tails = 0, phrase = 0, chord = 0;
  late final List<int> scale;

  _Performer(this.dev) {
    scale = keyIds.where((id) => id >= 17 && id < 51 && c1[id].abs() <= 3).toList()..sort((a, b) => pitchOf(a) - pitchOf(b));
  }

  double r() => dev.random.nextDouble();

  int pick(int? near) {
    if (near == null) return scale[dev.random.nextInt(scale.length)];
    final k = scale.indexOf(near);
    const steps = [-2, -1, -1, 1, 1, 2, 3];
    return scale[(k + steps[dev.random.nextInt(7)]).clamp(0, scale.length - 1)];
  }

  void start(int id, double t0, double dur, double peak, {double? strike, double? vib, double? swell}) {
    if (notes.any((n) => n.id == id && n.t1 + 0.12 > t0)) return;
    notes.add(_Note(id, t0, t0 + dur, peak, strike ?? 0.3 + 0.6 * r(), vib ?? 0.12 * r(), (r() - 0.5) * 1.2, swell ?? 0.6));
  }

  void step(double t) {
    if (t >= next && notes.length < 6) {
      final kind = phrase++ % 3;
      if (kind != 2) {
        var tt = t;
        for (var c = 0; c < 2; c++) {
          final ch = _progression[chord++ % _progression.length];
          final dur = 0.9 + 0.5 * r();
          final ids = _voiceChord(ch);
          for (var j = 0; j < ids.length; j++) {
            start(ids[j], tt + j * 0.025, dur, 0.4 + 0.25 * r(), swell: 0.9, vib: 0.04);
          }
          tt += dur + 0.12;
        }
        next = tt + 0.2;
      } else {
        var id = pick(null);
        var tt = t;
        final n = 4 + dev.random.nextInt(5);
        for (var j = 0; j < n; j++) {
          final last = j == n - 1;
          final d = last ? 1.1 + 0.6 * r() : 0.18 + 0.22 * r();
          start(id, tt, d + 0.04, 0.4 + 0.45 * r(), vib: last ? 0.35 : 0.05, swell: last ? 0.5 : 0.2);
          tt += d;
          id = pick(id);
        }
        next = tt + 0.35;
      }
    }
    shake = math.max(0, shake * 0.995);
    tails = 0;
    final keys = dev.keys;
    notes = notes.where((n) {
      if (t < n.t0) return true;
      final k = keys[n.id] ?? _Key();
      if (k.manual) return false;
      final age = t - n.t0;
      if (t >= n.t1) {
        if (k.pres > 0) {
          k.pres = 0;
          k.vpres = -0.2 - 0.3 * r();
          keys[n.id] = k;
        }
        tails++;
        return t < n.t1 + 0.3;
      }
      final attack = math.min(1.0, age / 0.05);
      final swell = 1 + n.swell * 0.35 * math.sin(math.min(1.0, age / (n.t1 - n.t0)) * math.pi);
      final pres = math.min(1.0, n.peak * attack * swell);
      final vibAmt = n.vib * math.min(1.0, math.max(0.0, age - 0.25) / 0.4);
      if (vibAmt > 0.2) shake = math.max(shake, vibAmt);
      k.vpres = age < 0.03 ? n.strike : (pres - k.pres) * 4;
      k.pres = math.max(0.002, pres);
      k.x = vibAmt * math.sin(age * 2 * math.pi * 5.4);
      k.y = n.tilt * math.min(1.0, age / 0.8) * (0.6 + 0.4 * math.sin(age * 1.7));
      keys[n.id] = k;
      return true;
    }).toList();
  }
}

int _clampInt(double v) {
  final r = v.round();
  return r > fullScale ? fullScale : (r < -8192 ? -8192 : r);
}

/// The mock board behind the Transport interface (demo mode, tests).
class MockTransport implements Transport {
  final MockBoard board;
  final Duration latency;
  final _data = StreamController<Uint8List>.broadcast(sync: true);
  final _lost = Completer<UsbError>();
  bool alive = false;

  MockTransport({MockBoard? board, this.latency = const Duration(milliseconds: 2)}) : board = board ?? MockBoard();

  @override
  String get label => 'Demo Striso (simulated)';
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => _lost.future;

  @override
  Future<void> open() async {
    alive = true;
    board.attach((bytes) {
      if (alive) _data.add(bytes);
    });
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (!alive) throw StateError('not connected');
    final copy = Uint8List.fromList(bytes);
    await Future<void>.delayed(latency);
    if (alive) board.receive(copy);
  }

  @override
  Future<void> close() async {
    if (alive) board.receive(Cmd.streamOff());
    alive = false;
    board.detach();
  }

  /// Simulate pulling the cable.
  void unplug() {
    if (!alive) return;
    alive = false;
    board.detach();
    if (!_lost.isCompleted) _lost.complete(UsbError.unplugged);
  }
}
