// A simulated Striso for development, demos and tests: the console commands of pconnection.c,
// voices with live parameters, touch settings and key factors, synth load, and a performer that
// plays the keys and moves the motion sensor. Output is interleaved and chunked like the real bulk
// endpoint: text can be split by binary messages and by 64 byte packets anywhere.
// Port of tools/app/js/mock.js.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'layout.dart';
import 'playable.dart';
import 'modules.dart';
import 'presets.dart';
import 'protocol.dart';
import 'board_state.dart';
import 'settings_map.dart';
import 'transport.dart';

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

/// voice_trumpet.h param_table (names, groups, ranges as the firmware's; plausible defaults).
const List<_P> _trumpet = [
  ('gain', 'level', 0.1, 4.0, 0, 1.0),
  ('p_soft', 'level', 0.3, 8.0, 0, 1.6),
  ('p_loud', 'level', 2.0, 20.0, 0, 9.0),
  ('pres_ff', 'level', 0.2, 1.5, 0, 0.8),
  ('resp_hz', 'level', 3.0, 100.0, 0, 30.0),
  ('release', 'level', 0.005, 0.5, 0, 0.06),
  ('lip_tune', 'lips', -300.0, 300.0, 0, 0.0),
  ('lip_q', 'lips', 0.5, 400.0, 0, 40.0),
  ('lip_mass', 'lips', 0.3, 3.0, 0, 1.0),
  ('lip_open', 'lips', -0.6, 0.6, 0, 0.0),
  ('lip_width', 'lips', 4.0, 14.0, 0, 8.0),
  ('tilt_lip', 'lips', -1.0, 1.0, 0, 0.3),
  ('cup', 'bore', 0.3, 2.0, 0, 1.0),
  ('bore_loss', 'bore', 0.0, 1.0, 0, 0.4),
  ('bell', 'bore', -6.0, 6.0, 0, 0.0),
  ('brassy', 'bore', 0.0, 8.0, 0, 1.0),
  ('breath', 'air', 0.0, 1.0, 0, 0.15),
  ('t_noise', 'air', 0.0, 1.0, 0, 0.2),
  ('attack', 'attack', 0.0, 2.0, 0, 1.0),
  ('overshoot', 'attack', 0.0, 1.0, 0, 0.3),
  ('vibrato', 'mod', 0.0, 1.0, 0, 0.1),
  ('vib_hz', 'mod', 3.0, 8.0, 0, 5.5),
  ('shake', 'mod', 0.0, 2.0, 0, 0.0),
  ('growl', 'mod', 0.0, 1.0, 0, 0.0),
  ('fall', 'bend', 0.0, 12.0, 0, 0.0),
  ('doit', 'bend', 0.0, 12.0, 0, 0.0),
  ('halfvalve', 'bend', 0.0, 1.0, 0, 0.0),
  ('mute', 'mute', 0.0, 1.0, 0, 0.0),
  ('wah', 'mute', -1.0, 1.0, 0, 0.0),
  ('legato', 'play', 0, 2, 1, 1),
  ('slur_thr', 'play', 0.0, 1.0, 0, 0.4),
  ('valve_ms', 'play', 3.0, 60.0, 0, 15.0),
  ('voices', 'play', 1, 4, 1, 1),
  ('room', 'room', 0.0, 1.0, 0, 0.3),
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
  ('dlmix', 'delay', 0.0, 1.0, 0, 0.2),
  ('dl_pong', 'delay', 0, 1, 2, 1),
  ('reverb', 'reverb', 0, 1, 2, 1),
  ('rv_size', 'reverb', 0.0, 1.0, 0, 0.55),
  ('rv_damp', 'reverb', 0.0, 1.0, 0, 0.4),
  ('rvmix', 'reverb', 0.0, 1.0, 0, 0.22),
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
  _Engine('trumpet', ['bb classical', 'bb jazz', 'c trumpet', 'piccolo', 'cornet', 'harmon', 'cup mute', 'straight', 'plunger'], _trumpet, 9400),
];

/// The engine ABI the mock runs (NSC_ABI): a slot of another ABI is listed disabled.
const mockEngineAbi = 1;

/// An engine the mock can run from a slot (modules.dart): its presets (none: one entry).
class MockComponent {
  final List<String> presets;
  const MockComponent(this.presets);
}

/// The engines the mock runs from a slot, by id; a package of another id installs (the firmware
/// takes any valid package) but gives no voices.
const mockComponents = <String, MockComponent>{
  'sax': MockComponent(['soprano sax', 'alto sax', 'tenor sax', 'baritone sax']),
  'clarinet': MockComponent(['clarinet', 'bass clarinet']),
  'sine': MockComponent([]),
};

/// The mock's own stand-in for an engine package: `NSCP`, a newline, then {id, version, abi} as
/// JSON (a real package is the firmware's to read; the mock refuses one).
List<int> mockModulePackage(String id, {String version = '1.0', int abi = mockEngineAbi, int padTo = 0}) {
  final b = [...'NSCP\n'.codeUnits, ...utf8.encode(jsonEncode({'id': id, 'version': version, 'abi': abi}))];
  return [...b, for (var i = b.length; i < padTo; i++) 0x20];
}

/// The mock's slots (2..6, as the board's), kept across mock boards as the board's flash keeps
/// them across restarts.
class MockModuleStore {
  final slots = <int, ({String id, String version, int abi, int bytes})>{};
  static const first = 2, count = 5;
}

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

/// The mock's tunings 0..8 (widget tests only), as the firmware's config.h has them: the fifth and
/// the octave in cents, the led colour and, for just intonation, the 17 per-key offsets in cents
/// from C (C Db C# D Eb D# E F Gb F# G Ab G# A Bb A# B). Their names are the StcX recording's.
const List<(double, double, int, List<double>?)> _mockTunings = [
  (700, 1200, 0x00aa00, null),
  (696.7742, 1200, 0x005555, null),
  (694.7368, 1200, 0x0000aa, null),
  (701.9550, 1200, 0x555500, null),
  (720, 1200, 0xaa0000, null),
  (685.7142, 1200, 0x550055, null),
  (585.2169, 1024.130, 0x55aa00, null),
  (1024.130, 1901.955, 0x55aa00, null),
  (
    696.7741,
    1200,
    0x00aa55,
    [
      0.0, -4.39774, -6.74692, 10.3616, 5.96386, -4.09683, -0.78306, // C Db C# D Eb D# E
      -5.18080, -1.86703, 1.86703, 5.18080, 0.78306, -1.56612, // F Gb F# G Ab G#
      -5.96386, -10.3616, 1.08397, 4.39774, // A Bb A# B
    ],
  ),
];

/// The firmware's StcH replies (after the voice index), as recorded from the virtual board for
/// every voice (striso-control-firmware mod-midiin 576794a). The mock (widget tests only) answers
/// with the one of its current voice's name.
const Map<String, String> mockHeroReplies = {
  'strisy': '| rvmix dlmix',
  'va:classic': 'cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix',
  'va:pad': 'cut_base cut_env release saw2_detune drift res sub vibrato | rvmix dlmix',
  'va:lead': 'cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix',
  'va:bass': 'cut_base res cut_env drive sub acc_level acc_cutoff release | rvmix dlmix',
  'va:brass': 'cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix',
  'va:keys': 'cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix',
  'va:acid': 'cut_base res cut_env drive acc_cutoff acc_level acc_decay release | rvmix dlmix',
  'va:strings': 'cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix',
  'modal:vibraphone': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'modal:marimba': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'modal:glockenspiel': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'modal:bell': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'modal:kalimba': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'modal:wine glass': 'hard decay upper keytrack hfdamp damper tremdepth rub | rvmix dlmix',
  'bowed:violin': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:viola': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:cello': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:bass': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:section': 'ensemble ens_detune ens_spread force_hi pos bright body_amt vibrato | rvmix dlmix',
  'bowed:ponticello': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:flautando': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:sordino': 'force_hi pos rosin bright body_amt damp vibrato ensemble | rvmix dlmix',
  'bowed:pizzicato': 'pizz_decay pizz_bright pos bright body_amt damp rel vibrato | rvmix dlmix',
  'wind:clarinet': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:bass clarinet': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:soprano sax': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:alto sax': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:tenor sax': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:baritone sax': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:oboe': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:bassoon': 'reed_open attack bright breath growl vib body tongue | rvmix dlmix',
  'wind:flute': 'jet jet_off breath turb bright attack vib body | rvmix dlmix',
  'ep:stage': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:suitcase': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:mk2': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:dyno': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:ballad': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:bark': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:neosoul': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:fm80s': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:lofi': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:wurli': 'wurli hard decay drive grit tone wobble dyn | rvmix dlmix',
  'ep:wurlibark': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:pianet': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:felt': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'ep:celesta': 'hard decay bell tick drive grit tone wobble | rvmix dlmix',
  'brass:trumpet': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:flugelhorn': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:trombone': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:horn': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:euphonium': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:tuba': 'brassiness lip_loud tone_hz breath mute release vibrato pair | rvmix dlmix',
  'brass:harmon': 'mute mute_bp mute_hz wah brassiness tone_hz vibrato release | rvmix dlmix',
  'brass:plunger': 'mute mute_lp mute_hz wah brassiness tone_hz vibrato release | rvmix dlmix',
  'brass:section': 'pair detune brassiness lip_loud tone_hz breath vibrato release | rvmix dlmix',
  'trumpet:bb classical': 'brassy bell attack p_loud breath vibrato release room | rvmix dlmix',
  'trumpet:bb jazz': 'brassy bell growl fall doit shake vibrato breath | rvmix dlmix',
  'trumpet:c trumpet': 'brassy bell attack p_loud breath vibrato release room | rvmix dlmix',
  'trumpet:piccolo': 'brassy bell attack p_loud breath vibrato release room | rvmix dlmix',
  'trumpet:cornet': 'brassy bell attack p_loud breath vibrato release room | rvmix dlmix',
  'trumpet:harmon': 'mute wah brassy bell attack breath vibrato room | rvmix dlmix',
  'trumpet:cup mute': 'mute wah brassy bell attack breath vibrato room | rvmix dlmix',
  'trumpet:straight': 'mute wah brassy bell attack breath vibrato room | rvmix dlmix',
  'trumpet:plunger': 'mute wah growl brassy bell fall vibrato breath | rvmix dlmix',
};

/// The firmware's StcX reply, as recorded from the virtual board (striso-control-firmware's
/// virtual/tests/transcripts/settings_layout.txt). The mock (widget tests only) answers with it.
const mockSettingsLayoutReply = [
  'X keys 42',
  'X 0 switch midi - - k MPE|MPE MIDI mode|number of MPE voices, 1 to 15',
  'X 2 switch midi - - k Poly|Normal MIDI mode (all notes on one channel)|MIDI channel, 1 to 16',
  'X 4 switch midi - - k Mono|Mono (glissando) MIDI mode|MIDI channel, 1 to 16',
  'X 6 dial sens - - - Bend|Pitch bend sensitivity (sideways tilt)|0 to 4, steps of 1/4',
  'X 8 dial sens - - - Tilt|Tilt (forward/back) sensitivity|0 to 3, steps of 1/8',
  'X 9 switch layout - - k Legato|Mono legato: one internal voice, a key pressed while one is held slurs to it, its release returns to the held one (on/off)|on/off',
  'X 11 action layout - - - Flip|Flip the layout 180 degrees (with the glissando button also held: debug mode on/off)|',
  'X 13 switch voice brass 402800 k brass|Voice: brass|step through its presets (the up/down leds show which)',
  'X 15 switch voice trumpet 003030 k tpt|Voice: trumpet|step through its presets (the up/down leds show which)',
  'X 17 dial sens - - - Thres|Note-on threshold|how light a touch starts a note (led dial 0 to 15)',
  'X 18 switch voice strisy 282828 k strisy|Voice: strisy|step through its presets (the up/down leds show which)',
  'X 19 dial sens - - - Press|Pressure sensitivity|0 to 3, steps of 1/8',
  'X 20 switch voice va 401400 k va|Voice: va|step through its presets (the up/down leds show which)',
  'X 21 dial sens - - - Velo|Velocity sensitivity|0 to 2, steps of 1/8',
  'X 22 switch voice modal 001840 k modal|Voice: modal|step through its presets (the up/down leds show which)',
  'X 23 switch tuning - - k Pyth|Tuning 3: Pythagorean|fine tuning offset, 1/32 semitone per step',
  'X 24 switch voice bowed 400000 k bowed|Voice: bowed|step through its presets (the up/down leds show which)',
  'X 25 switch tuning - - k 5TET|Tuning 4: 5-TET|fine tuning offset, 1/32 semitone per step',
  'X 26 switch voice wind 004000 k wind|Voice: wind|step through its presets (the up/down leds show which)',
  'X 27 switch tuning - - k 7TET|Tuning 5: 7-TET|fine tuning offset, 1/32 semitone per step',
  'X 28 switch voice ep 280040 k ep|Voice: ep|step through its presets (the up/down leds show which)',
  'X 29 switch tuning - - k BP1|Tuning 6: Bohlen-Pierce 1|fine tuning offset, 1/32 semitone per step',
  'X 30 switch preset - - k P7|Load settings preset 7|',
  'X 31 switch tuning - - k BP2|Tuning 7: Bohlen-Pierce 2|fine tuning offset, 1/32 semitone per step',
  'X 32 switch preset - - k P8|Load settings preset 8|',
  'X 33 switch tuning - - k Just|Tuning 8: Just 7-limit|fine tuning offset, 1/32 semitone per step',
  'X 34 switch tuning - - k 12TET|Tuning 0: 12-TET|fine tuning offset, 1/32 semitone per step',
  'X 35 switch preset - - k P1|Load settings preset 1|',
  'X 36 switch tuning - - k 31TET|Tuning 1: 31-TET|fine tuning offset, 1/32 semitone per step',
  'X 37 switch preset - - k P2|Load settings preset 2|',
  'X 38 switch tuning - - k 19TET|Tuning 2: 19-TET|fine tuning offset, 1/32 semitone per step',
  'X 39 switch preset - - k P3|Load settings preset 3|',
  'X 41 switch preset - - k P4|Load settings preset 4|',
  'X 43 switch preset - - k P5|Load settings preset 5|',
  'X 45 switch preset - - k P6|Load settings preset 6|',
  'X 51 dial midi2 - - - Vol|Volume (MIDI CC7)|volume, 0 to 127',
  'X 53 dial midi2 - - - Sust|Sustain / decay (pedal)|release length, 0 to 1',
  'X 56 dial midi2 - - - MPEbd|MPE pitch bend range|12, 24, 48 or 96 semitones',
  'X 58 dial midi2 - - - Rate|MIDI message interval|1 to 15 ms',
  'X 63 switch system - - k Panic|Panic: all MIDI notes off|',
  'X 65 action system - - - Cfg|Send the MPE and pitch bend configuration over MIDI|',
  'X 67 action system - - d Reset|System reset: restarts the Striso|',
  'X end',
];

final SettingsLayout mockSettingsLayout = parseSettingsLayout(mockSettingsLayoutReply)!;

class MockBoard implements PlayableBoard {
  /// Mono legato, as the firmware reports it (StcY legato=) and switches it (StcK on key 9).
  int legato = 0;

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

  /// The engine-module slots (null: a firmware without them, which answers "m err no module
  /// store" and lists none); the ones that read ok load at boot, after the built-in engines.
  final MockModuleStore? modules;

  /// The firmware as released upstream (v2.2.4): it does not answer StcX, StcY, Stcy, StcH or
  /// the preset commands.
  final bool stockFirmware;

  /// The preset store (doc/presets_console.md): off answers "store off" to the user's presets;
  /// the user's presets by id, as stored (the text byte for byte), the next id, and how many may
  /// be kept.
  bool presetStore;
  final userPresets = <int, String>{};
  int _nextPresetId = 1;
  int presetLimit = 128;

  MockBoard({
    this.modules,
    this.stockFirmware = false,
    this.presetStore = true,
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
    _loadModules();
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
        if (_rxCmd == 't') {
          final n = int.tryParse(String.fromCharCodes(p)) ?? -1;
          if (n >= 49 && n <= 256) usbAudioTarget = n;
          if (n == 0 || (n >= 49 && n <= 256)) _print('usb audio target $usbAudioTarget frames (${usbAudioTarget * 1000000 ~/ 48000} us)\r\n');
        } else if (_rxCmd == PresetCodes.text) {
          _presetText(p[0] | p[1] << 8);
        } else if (_rxCmd == PresetCodes.delete) {
          _presetDelete(p[0] | p[1] << 8);
        } else if (_rxCmd == PresetCodes.open) {
          _presetOpen(p[0] | p[1] << 8);
        } else if (_rxCmd == ModuleCodes.erase) {
          final k = p[0] - 0x30;
          final m = modules;
          if (m == null) {
            _print('m err no module store\r\n');
          } else if (k < MockModuleStore.first || k >= MockModuleStore.first + MockModuleStore.count) {
            _print('m err no slot ${String.fromCharCode(p[0])} (slots ${MockModuleStore.first}..${MockModuleStore.first + MockModuleStore.count - 1})\r\n');
          } else {
            m.slots.remove(k);
            _print('m erased $k\r\n');
          }
        } else if (_rxCmd == ModuleCodes.install && _moduleLength == null) {
          // the 5-byte payload: then the package, taken whole even when refused (none of it read
          // as a command), as the firmware's
          final dest = p[0], n = p[1] | p[2] << 8 | p[3] << 16 | p[4] << 24;
          _rxPayload.clear();
          String? refused;
          if (dest != 0x73) {
            refused = 'dest ${String.fromCharCode(dest)}: only \'s\' (a slot)';
          } else if (modules == null) {
            refused = 'no module store';
          } else if (n == 0) {
            refused = 'empty';
          }
          if (refused != null) {
            _print('m err $refused\r\n');
          } else {
            final m = modules!;
            final free = MockModuleStore.count - m.slots.length;
            _print('m begin ok mock $free\r\n');
          }
          _moduleRefused = refused != null;
          _moduleLength = n;
          _rxNeed = n;
          if (n == 0) _moduleLength = null;
        } else if (_rxCmd == ModuleCodes.install) {
          _moduleLength = null;
          if (!_moduleRefused) _moduleInstall(List<int>.of(p));
        } else if (_rxCmd == PresetCodes.upload && _upKind == null) {
          // the 5-byte payload: then the bytes (an upload)
          _upKind = p[0];
          final n = p[1] | p[2] << 8 | p[3] << 16 | p[4] << 24;
          _rxCmd = PresetCodes.upload;
          _rxPayload.clear();
          if (n == 0) {
            _presetUpload(_upKind!, const []);
            _upKind = null;
          } else {
            _rxNeed = n;
          }
        } else if (_rxCmd == PresetCodes.upload) {
          final k = _upKind!;
          _upKind = null;
          _presetUpload(k, List<int>.of(p));
        } else if (_rxCmd == 'K') {
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
      _select(c - 0x80);
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
    } else if (ch == 'X' && !stockFirmware) {
      for (final l in mockSettingsLayoutReply) {
        _print('$l\r\n');
      }
    } else if (ch == 'H' && !stockFirmware) {
      final name = _entries[voice].name;
      _print('H $voice ${heroReply?.call(name) ?? mockHeroReplies[name] ?? '| rvmix dlmix'}\r\n');
    } else if (!stockFirmware && ch == ModuleCodes.slots) {
      _moduleSlots();
    } else if (!stockFirmware && ch == ModuleCodes.install) {
      _rxNeed = 5;
      _rxCmd = ch;
      _rxPayload.clear();
    } else if (!stockFirmware && ch == ModuleCodes.erase) {
      _rxNeed = 1;
      _rxCmd = ch;
      _rxPayload.clear();
    } else if (!stockFirmware && ch == PresetCodes.list) {
      _presetList();
    } else if (!stockFirmware && (ch == PresetCodes.text || ch == PresetCodes.delete || ch == PresetCodes.open)) {
      _rxNeed = 2;
      _rxCmd = ch;
      _rxPayload.clear();
    } else if (!stockFirmware && ch == PresetCodes.upload) {
      _rxNeed = 5;
      _rxCmd = ch;
      _rxPayload.clear();
    } else if (ch == 'Y' && !stockFirmware) {
      _print('${_stateLine()}\r\n');
    } else if (ch == 'y' && !stockFirmware) {
      _stateLine();
      _print('y $_stateCount\r\n');
    } else if (ch == 'U') {
      _printUsbAudio();
    } else if (ch == 't') {
      _rxNeed = 3;
      _rxCmd = 't';
      _rxPayload.clear();
    } else if (ch == 'I') {
      _print('stklimit    stack     addr   unused refs prio     state         name\r\n(mock device)\r\n');
    } else if (ch == 'P') {
      _print('profile over 1500 blocks, voice ${_entries[voice].name}, mock\r\n');
    }
  }

  // the slots that read ok, as the firmware lists them at boot: after its own engines
  void _loadModules() {
    final m = modules;
    if (m == null) return;
    for (final k in [...m.slots.keys]..sort()) {
      final e = m.slots[k]!;
      final c = mockComponents[e.id];
      if (c == null || e.abi != mockEngineAbi) continue;
      final first = _entries.length;
      final eng = _Engine(e.id, c.presets.isEmpty ? null : c.presets, _reed, 9000);
      if (c.presets.isEmpty) {
        _entries.add(_Entry(e.id, null, eng, first * 7));
      } else {
        for (var j = 0; j < c.presets.length; j++) {
          _entries.add(_Entry(e.id, c.presets[j], eng, first * 7 + j));
        }
      }
    }
  }

  void _moduleSlots() {
    final m = modules;
    if (m != null) {
      for (var k = MockModuleStore.first; k < MockModuleStore.first + MockModuleStore.count; k++) {
        final e = m.slots[k];
        if (e == null) {
          _print('slot $k empty\r\n');
        } else {
          final why = e.abi != mockEngineAbi ? 'disabled: abi ${e.abi}, firmware has $mockEngineAbi' : 'ok';
          _print('slot $k ${e.id} ${e.version} ${e.abi} ${e.bytes} $why\r\n');
        }
      }
    }
    _print('slot end\r\n');
  }

  int? _moduleLength;
  bool _moduleRefused = false;

  void _moduleInstall(List<int> bytes) {
    final m = modules!;
    for (var o = 4096; o <= bytes.length; o += 4096) {
      _print('m $o ${crc32(bytes, end: o).toRadixString(16).padLeft(8, '0')}\r\n');
    }
    Map<Object?, Object?>? j;
    if (bytes.length > 5 && String.fromCharCodes(bytes.sublist(0, 5)) == 'NSCP\n') {
      try {
        final t = utf8.decode(bytes.sublist(5)).trim();
        final o = jsonDecode(t);
        if (o is Map) j = o;
      } catch (_) {}
    }
    if (j == null || j['id'] is! String) {
      _print('m err not a package the mock reads\r\n');
      return;
    }
    // the first free slot (a reinstall of an id replaces it, as the firmware's installer does)
    final had = m.slots.entries.where((e) => e.value.id == j!['id']).map((e) => e.key).firstOrNull;
    var k = had ?? -1;
    for (var s = MockModuleStore.first; k < 0 && s < MockModuleStore.first + MockModuleStore.count; s++) {
      if (!m.slots.containsKey(s)) k = s;
    }
    if (k < 0) {
      _print('m err no free slot\r\n');
      return;
    }
    final e = (id: j['id'] as String, version: '${j['version'] ?? '-'}', abi: (j['abi'] as num?)?.toInt() ?? 0, bytes: bytes.length);
    m.slots[k] = e;
    _print('m ok $k ${e.id} ${e.version} ${e.abi}\r\n');
  }

  int? _upKind;

  // the factory presets: the voice entries, by engine number (its order in the voice list) and
  // its preset
  int _factoryId(int n) {
    final engines = <String>[];
    for (final e in _entries) {
      if (!engines.contains(e.engine)) engines.add(e.engine);
    }
    final k = engines.indexOf(_entries[n].engine);
    final j = _entries.sublist(0, n).where((e) => e.engine == _entries[n].engine).length;
    return factoryPresetBase + 256 * k + j;
  }

  int _entryOf(int id) {
    for (var n = 0; n < _entries.length; n++) {
      if (_factoryId(n) == id) return n;
    }
    return -1;
  }

  String _word(String? s) => s == null || s.isEmpty ? '-' : s.replaceAll(RegExp(r'[\s\x00-\x1f\x7f]'), '_');
  String _rest(String s) => s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  String _title(String s) => _rest(s).replaceAll('|', '/');

  Map<String, Object?>? _json(String text) {
    try {
      final j = jsonDecode(text);
      return j is Map<String, Object?> ? j : null;
    } catch (_) {
      return null;
    }
  }

  void _presetList() {
    var n = 0;
    for (var i = 0; i < _entries.length; i++) {
      _print('J ${_factoryId(i)} ${_word(_entries[i].engine)} - ${_title(_entries[i].preset ?? _entries[i].engine)}|\r\n');
      n++;
    }
    if (!presetStore) {
      _print('J store off\r\n');
    } else {
      for (final e in userPresets.entries) {
        final j = _json(e.value);
        final eng = j?['engine'];
        if (j == null || eng is! Map) {
          _print('J ${e.key} ? - (unreadable)|\r\n');
        } else {
          final d = j['description'] is String ? _rest(j['description'] as String) : '';
          _print('J ${e.key} ${_word(eng['id'] as String?)} ${_word(eng['version'] as String?)} ${_title('${j['title'] ?? ''}')}|$d\r\n');
        }
        n++;
      }
    }
    _print('J end $n\r\n');
  }

  // a voice entry's values as a preset text (the board writes it: kind 2, and j of a factory id)
  String _presetOf(int n, String title, String? description, {bool factory = false}) {
    final e = _entries[n];
    final params = e.eng.params;
    final vals = n == voice ? values : _presetValues(params, e.seed);
    final m = <String, Object?>{
      'format': 'awva-preset/1',
      // a factory file names no version; a saved one has the firmware's
      'engine': {'id': e.engine, if (!factory) 'version': firmware, 'params_hash': 'm0c4${e.engine.length.toRadixString(16).padLeft(4, '0')}'},
      'title': title,
      if (description != null && description.isNotEmpty) 'description': description,
      'params': {for (var i = 0; i < params.length; i++) params[i].$1: vals[i].clamp(params[i].$3, params[i].$4)},
    };
    return '${const JsonEncoder.withIndent('  ').convert(m)}\n';
  }

  void _presetText(int id) {
    String? t;
    if (id >= factoryPresetBase) {
      final n = _entryOf(id);
      if (n < 0) {
        _print('j err no preset $id\r\n');
        return;
      }
      if (_entries[n].preset == null) {
        _print('j err no text $id\r\n'); // an engine without presets
        return;
      }
      t = _presetOf(n, _entries[n].preset!, null, factory: true);
    } else if (!presetStore) {
      _print('j err store off\r\n');
      return;
    } else {
      t = userPresets[id];
      if (t == null) {
        _print('j err no preset $id\r\n');
        return;
      }
    }
    final bytes = utf8.encode(t);
    _print('j $id ${bytes.length}\r\n');
    final lines = t.endsWith('\n') ? t.substring(0, t.length - 1).split('\n') : t.split('\n');
    for (final l in lines) {
      _print('$l\r\n');
    }
    _print('j end\r\n');
  }

  void _presetUpload(int kind, List<int> bytes) {
    // in the firmware's order: what is refused at the start, then a byte >= 0x80, then the text
    if (!presetStore) return _print('F err store off\r\n');
    if (kind != 1 && kind != 2) return _print('F err kind\r\n');
    if (bytes.length > (kind == 1 ? presetMaxText : presetMaxFields)) return _print('F err too long\r\n');
    final high = bytes.indexWhere((b) => b >= 0x80);
    if (high >= 0) return _print('F err not ascii $high\r\n');
    String text;
    if (kind == 1) {
      if (bytes.isEmpty) return _print('F err empty\r\n');
      text = utf8.decode(bytes, allowMalformed: true);
      final j = _json(text);
      if (j == null) return _print('F err syntax\r\n');
      if (j['format'] != 'awva-preset/1') return _print('F err no_format\r\n');
      final eng = j['engine'];
      if (eng is! Map || eng['id'] is! String) return _print('F err no_engine\r\n');
      if (!_entries.any((e) => e.engine == eng['id'])) return _print('F err engine ${_word(eng['id'] as String)}\r\n');
    } else {
      final f = _json(utf8.decode(bytes, allowMalformed: true));
      final title = f?['title'] ?? '', desc = f?['description'] ?? '';
      if (f == null || title is! String || desc is! String) return _print('F err fields\r\n');
      if (utf8.encode(title).length > presetMaxTitle || utf8.encode(desc).length > presetMaxDescription) return _print('F err fields\r\n');
      text = _presetOf(voice, title, desc);
    }
    if (userPresets.length >= presetLimit) return _print('F err too many\r\n');
    final id = _nextPresetId++;
    userPresets[id] = text;
    _print('F ok $id\r\n');
  }

  void _presetDelete(int id) {
    final c = PresetCodes.delete;
    if (id >= factoryPresetBase) return _print('$c err factory $id\r\n');
    if (!presetStore) return _print('$c err store off\r\n');
    if (userPresets.remove(id) == null) return _print('$c err no preset $id\r\n');
    _print('$c ok $id\r\n');
  }

  void _presetOpen(int id) {
    if (id >= factoryPresetBase) {
      final n = _entryOf(id);
      if (n < 0) return _print('O err no preset $id\r\n');
      _select(n, quiet: true);
      return _print('O ok $id voice $n exact\r\n');
    }
    if (!presetStore) return _print('O err store off\r\n');
    final t = userPresets[id];
    if (t == null) return _print('O err no preset $id\r\n');
    final j = _json(t);
    final eng = j?['engine'];
    if (j == null || eng is! Map) return _print('O err unreadable $id\r\n');
    final n = _entries.indexWhere((e) => e.engine == eng['id']);
    if (n < 0) return _print('O err engine ${_word('${eng['id']}')}\r\n');
    _select(n, quiet: true);
    // by name: out of range clamped, unknown skipped, absent missing (keeps the voice's value)
    final params = _entries[n].eng.params;
    final given = j['params'] is Map ? (j['params'] as Map).cast<String, Object?>() : const <String, Object?>{};
    final clamped = <String>[], skipped = <String>[];
    var missing = 0;
    for (final k in given.keys) {
      if (!params.any((p) => p.$1 == k)) skipped.add(k);
    }
    for (var i = 0; i < params.length; i++) {
      final v = given[params[i].$1];
      if (v is! num) {
        missing++;
        continue;
      }
      final c = v.toDouble().clamp(params[i].$3, params[i].$4);
      if (c != v.toDouble()) clamped.add(params[i].$1);
      values[i] = conformTo(params[i].$3, params[i].$4, params[i].$5, c, 0);
    }
    if (clamped.isEmpty && skipped.isEmpty && missing == 0) return _print('O ok $id voice $n exact\r\n');
    _print('O ok $id voice $n clamped ${clamped.length} skipped ${skipped.length} missing $missing\r\n');
    if (clamped.isNotEmpty) _print('O clamped ${clamped.take(16).map(_word).join(' ')}\r\n');
    if (skipped.isNotEmpty) _print('O skipped ${skipped.take(16).map(_word).join(' ')}\r\n');
  }

  // a voice-list entry chosen (0x80 + n, a preset opened)
  void _select(int n, {bool quiet = false}) {
    if (n < _entries.length) {
      voice = n;
      values = _presetValues(_entries[n].eng.params, _entries[n].seed);
      if (!quiet) _print('voice $n ${_entries[n].name}\r\n');
    } else if (!quiet) {
      _print('no voice $n\r\n');
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
  /// Board-side USB audio drops the demo reports at the next StcU (tests).
  int usbAudioUnderruns = 0, usbAudioHostSkipped = 0;

  /// The USB audio ring target (Stct), frames.
  int usbAudioTarget = 96;
  DateTime _usbAudioAt = DateTime.now();

  /// StcU as the firmware prints it (usb_audio.c), counters since the last call.
  void _printUsbAudio() {
    final now = DateTime.now();
    final ms = now.difference(_usbAudioAt).inMilliseconds.clamp(1, 600000);
    _usbAudioAt = now;
    final und = usbAudioUnderruns, skip = usbAudioHostSkipped;
    usbAudioUnderruns = usbAudioHostSkipped = 0;
    final t = usbAudioTarget;
    _print('usb audio (UAC2): streaming 48000 Hz 24 bit (alt 1), source synth\r\n');
    _print(
      'since last U: packets sent $ms missed $skip (host skipped $skip, flushed early 0); built $ms (47:${ms ~/ 400} 48:${ms - 2 * (ms ~/ 400)} 49:${ms ~/ 400})\r\n',
    );
    _print('rate: ${ms * 48} frames in $ms ms of host clock = 48000.000 Hz\r\n');
    _print('ring: level ${t + 8} now, $t filtered, ${t - 31}..${t + 32} before packets (target $t = ${t * 1000000 ~/ 48000} us, of 512)\r\n');
    _print('faults: underruns $und overruns 0 primes $und (silent packets 0), fast starts 1\r\n');
    _print('frames: not ready at SOF 0; SOF late (>1.1 ms) 0 lost 0, max interval 1012 us\r\n');
    _print('builds: after fetch $ms, after miss 0, at SOF 1; fetch at 95..140 us (avg 110) after SOF; build avg 1900 max 2600 cycles\r\n');
    _print('synth: commit 210 us avg, 420 max after its DMA interrupt (block 667 us); off cadence 0; since boot: blocks lost 0, repeated 0\r\n');
    _print('cpu: usb audio ISR hooks 9000000 cycles = 0.22% over $ms ms; longest lock: thread 12 us, ISR 4 us\r\n');
  }

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
    final (fifth, octave, color, offsets) = _mockTunings[n.clamp(0, _mockTunings.length - 1)];
    tuning = n.clamp(0, _mockTunings.length - 1);
    notegen1 = toFloat32(fifth / 100);
    notegen0 = toFloat32(octave / 100);
    tuningColor = color;
    for (var k = 0; k < 61; k++) {
      keyOffset[k] = toFloat32((offsets == null ? 0 : offsets[(k + 7) % 17]) / 100);
    }
  }

  /// The fine tune in cents (the knob on the tuning keys), e.g. -31.77 for A = 432 Hz.
  void fineTune(double cents) => noteOffset = toFloat32(cents / 100);

  /// Replaces the recorded StcH reply (after the voice index) for a voice name (tests).
  String? Function(String voice)? heroReply;

  int _stateCount = 0;
  String _stateSeen = '';

  /// StcY's line from this mock's state; the counter goes up when it differs from the last look.
  String _stateLine() {
    String f3(double v) => v.toStringAsFixed(3);
    final body =
        'voice=$voice midi=$midiMode ch=${midiMode == 'mpe' ? 2 : 1} voices=10 bend=48 tuning=$tuning '
        'fine=${(noteOffset * 100).toStringAsFixed(2)} transpose=0.000 pres=${f3(touch[0])} velo=${f3(touch[1])} '
        'tilt=${f3(touch[2])} bendsens=${f3(touch[3])} thres=${f3(touch[4])} vol=90 sustain=0.188 rate=1 '
        'alt=${(controlsDown[3]) != 0 ? 1 : 0} porta=0 flip=0 led=00AA00 updown=0000 legato=$legato';
    final snap = '$body ${values.join(',')} ${keyFactors.join(',')}';
    if (snap != _stateSeen) {
      if (_stateSeen.isNotEmpty) _stateCount++;
      _stateSeen = snap;
    }
    return 'Y $_stateCount $body';
  }

  /// StcK: a settings key pressed over USB (config_but with type 0). True when the key is one the
  /// board switches: MIDI modes, tunings, settings presets, voices, Panic; dials and system keys
  /// are refused.
  bool settingsKey(int id) {
    final f = mockSettingsLayout[id];
    if (f == null || !f.switchable) return false;
    if (id == 9) {
      legato = 1 - legato;
      return true;
    }
    if (f.group == SettingsGroup.midi) {
      midiMode = const {0: 'mpe', 2: 'poly', 4: 'mono'}[id]!;
      return true;
    }
    if (f.group == SettingsGroup.tuning) {
      loadTuning(int.parse(RegExp(r'Tuning (\d)').firstMatch(f.title)!.group(1)!));
      return true;
    }
    if (f.group == SettingsGroup.preset) {
      // a stored preset: the touch settings as saved (preset 1), the defaults for the others
      settingsPreset = int.parse(f.short.substring(1));
      final saved = _config?.touch;
      for (var i = 0; i < _touch.length; i++) {
        touch[i] = settingsPreset == 1 && saved != null && i < saved.length ? saved[i] : _touch[i].$6;
      }
      return true;
    }
    if (f.engine != null) {
      // config_voice: the engine with the preset it had last
      final list = [
        for (var n = 0; n < _entries.length; n++)
          if (_entries[n].engine == f.engine) n,
      ];
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

  @override
  void press(int id, {double pres = 0.5, double x = 0, double y = 0, double strike = 0}) {
    final k = keys.putIfAbsent(id, _Key.new);
    k.vpres = math.max(strike, (pres - k.pres) * 3);
    k.pres = math.max(0.001, pres);
    k.x = x;
    k.y = y;
    k.manual = true;
  }

  @override
  void release(int id, [double lift = 0.3]) {
    final k = keys[id];
    if (k != null) {
      k.pres = 0;
      k.vpres = -lift;
    }
  }

  @override
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
