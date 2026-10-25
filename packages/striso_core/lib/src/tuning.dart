// The board's tuning: the `StcN` reply (what every key actually plays), its name as the board's
// settings layout gives it (StcX), and the quarter-tone notation of a pitch. No tuning table here:
// the firmware has them.
//
// Firmware (synth_control.cpp): a key's pitch in semitones is
//   note = start_note_offset + tuning_note_offset[key] + notegen0 * coord0 + notegen1 * coord1 + note_offset
// with notegen0 the octave (12.0 in 12-TET), notegen1 the fifth (7.0), note_offset the fine tune
// (the tuning's own offset plus the knob on the tuning keys, 1/32 semitone per step) and per-key
// offsets for just intonation. load_tuning(n) reads fT<n>fifth, fT<n>oct, fT<n>off and the 61
// per-key cents from the configuration.
//
// The N reply (floats as 8 hex digits of their IEEE bits, like 'g' and 'k'):
//   tuning <cur_tuning> <fifth> <octave> <offset> <color> <base> <count>
//   <n> <name> <pitch> <key_offset>      (61 lines, n = key number 0..60, put_button_name names)
// cur_tuning is load_tuning's index (0 = 12-TET, -1 after the fifth was changed on the settings
// key); fifth/octave/offset are notegen1/notegen0/note_offset in semitones, offset including the
// fine tune; color is %06x; base is start_note_offset (the transposition, 62 = D); pitch is what
// the key plays if pressed now (MIDI-like semitones, before bend); key_offset the key's own tuning
// offset (0 unless the tuning has per-key offsets, like Just). The parser also takes decimal
// numbers, cents where semitones would be absurd, a header without the trailing fields, lines
// without the key offset, missing or repeated key lines and noise lines.

import 'dart:math' as math;

import 'board_state.dart';
import 'layout.dart';
import 'protocol.dart';

const double _fifthTol = 0.02, _octaveTol = 0.05; // cents

/// The tuning as the board reports it.
class TuningInfo {
  /// cur_tuning: 0..8 a settings-card tuning, -1 a changed generator (custom).
  final int index;

  /// Generators in semitones (notegen1, notegen0) and the global offset (note_offset).
  final double fifth, octave, offset;
  final int? color;

  /// Key number (0..60) to the pitch it plays, MIDI-like semitones (69 = A440).
  final Map<int, double> notes;

  /// Key number to the key's own tuning offset (semitones), when the reply gives it.
  final Map<int, double> keyOffsets;

  /// start_note_offset: the transposition (62 = D4 in the middle), when the reply gives it.
  final double? base;
  const TuningInfo({
    required this.index,
    required this.fifth,
    required this.octave,
    required this.offset,
    this.color,
    this.notes = const {},
    this.keyOffsets = const {},
    this.base,
  });

  double get fifthCents => fifth * 100;
  double get octaveCents => octave * 100;
  double get offsetCents => offset * 100;
  bool get complete => notes.length >= 61;

  /// The pitch of a key by its button id (null when the reply lacked it).
  double? pitchOfButton(int id) {
    final n = keyNumberOf[id];
    return n == null ? null : notes[n];
  }

  /// Plain 12-TET at A440 with no offset: the spelled names say it all.
  bool get isPlain12 => (fifthCents - 700).abs() < _fifthTol && (octaveCents - 1200).abs() < _octaveTol && offsetCents.abs() < 0.5 && !hasKeyOffsets;

  /// Per-key offsets beyond the generators (just intonation): reported as such, or the keys'
  /// pitches do not all fit base + octave * c0 + fifth * c1 for one base.
  bool get hasKeyOffsets => keyOffsets.isNotEmpty ? keyOffsets.values.any((o) => o.abs() * 100 > 0.5) : keyOffsetSpread > 0.5;

  /// The spread (cents) of the per-key residuals around their median.
  double get keyOffsetSpread {
    final res = <double>[];
    for (final MapEntry(key: n, value: p) in notes.entries) {
      if (n < 0 || n >= buttonNumberMap.length) continue;
      final id = buttonNumberMap[n];
      res.add((p - octave * c0[id] - fifth * c1[id]) * 100);
    }
    if (res.length < 2) return 0;
    res.sort();
    final med = res[res.length ~/ 2];
    return res.fold(0.0, (m, r) => math.max(m, (r - med).abs()));
  }

  /// The tuning's name, as the board names it: the settings card's tuning [index] by its key in
  /// the board's settings layout (StcX: "Tuning 1: 31-TET", short "31TET"; a tuning renamed in the
  /// configuration has that name); a changed generator (index -1) is custom, with its values.
  ({String name, String short}) nameIn(SettingsLayout layout) {
    if (index >= 0) {
      for (final k in layout.keys.values) {
        if (k.tuningIndex != index) continue;
        final i = k.title.indexOf(': ');
        return (name: i >= 0 ? k.title.substring(i + 2) : k.title, short: k.short);
      }
    }
    if (hasKeyOffsets) return (name: 'custom: per-key offsets', short: 'custom');
    final oct = (octaveCents - 1200).abs() < _octaveTol ? '' : ', octave ${octaveCents.toStringAsFixed(1)} ¢';
    return (name: 'custom: fifth ${fifthCents.toStringAsFixed(1)} ¢$oct', short: 'custom');
  }

  /// The fine tune as a reference pitch: "A = 432.0 Hz (−32 ¢)", or null when there is none.
  String? get referenceText {
    final c = offsetCents;
    if (c.abs() < 0.5) return null;
    final hz = 440 * math.pow(2, c / 1200);
    final sign = c < 0 ? '−' : '+';
    return 'A = ${hz.toStringAsFixed(hz.abs() < 100 ? 2 : 1)} Hz ($sign${c.abs().round()} ¢)';
  }

  @override
  String toString() => 'TuningInfo(index $index, ${notes.length} keys, offset ${offsetCents.toStringAsFixed(1)} ¢)';
}

final _hex8 = RegExp(r'^[0-9a-fA-F]{8}$');

/// The reply's first line, `tuning <index> <fifth> <octave> <offset> [color [base [count]]]`.
final tuningHeaderLine = RegExp(
  r'^\s*tuning\s+(-?\d+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+#?([0-9a-fA-F]{6}))?(?:\s+(\S+))?(?:\s+(\d+))?\s*$',
  caseSensitive: false,
);

/// A key line, `<n> <name> <pitch> [key_offset]`.
final tuningKeyLine = RegExp(r'^\s*(\d+)\s+(\S+)\s+(\S+)(?:\s+(\S+))?\s*$');
final _header = tuningHeaderLine, _keyLine = tuningKeyLine;

/// A float as the firmware prints it (8 hex digits of the bits) or as a decimal; null otherwise.
double? parseNumber(String s) {
  if (_hex8.hasMatch(s)) {
    final v = hexToFloat(s);
    return v.isFinite ? v : null;
  }
  final v = double.tryParse(s);
  return v != null && v.isFinite ? v : null;
}

/// The reply to StcN, or null when nothing of it is there (old firmware answers with nothing).
TuningInfo? parseTuningReply(List<String> lines) {
  int? index;
  double? fifth, octave, offset, base;
  int? color;
  final notes = <int, double>{}, keyOffsets = <int, double>{};
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final h = _header.firstMatch(line);
    if (h != null) {
      final f = parseNumber(h[2]!), o = parseNumber(h[3]!), off = parseNumber(h[4]!);
      if (f == null || o == null) continue;
      index = int.parse(h[1]!);
      // the generators are semitones (7.0); cents (700) are taken too
      fifth = f.abs() > 50 ? f / 100 : f;
      octave = o.abs() > 50 ? o / 100 : o;
      offset = off == null ? 0 : (off.abs() > 12 ? off / 100 : off);
      if (h[5] != null) color = int.parse(h[5]!, radix: 16);
      final b = h[6] == null ? null : parseNumber(h[6]!);
      if (b != null && b > 0 && b < 150) base = b;
      continue;
    }
    final k = _keyLine.firstMatch(line);
    if (k == null) continue;
    final n = int.parse(k[1]!);
    if (n < 0 || n > 60) continue;
    var p = parseNumber(k[3]!);
    if (p == null) continue;
    if (p > 200) p /= 100; // cents instead of semitones
    if (p < 0 || p > 150) continue;
    notes[n] = p;
    final o = k[4] == null ? null : parseNumber(k[4]!);
    if (o != null) keyOffsets[n] = o.abs() > 12 ? o / 100 : o;
  }
  if (fifth == null || octave == null) {
    if (notes.isEmpty) return null;
    // key lines without a header: generators unknown, take 12-TET's
    return TuningInfo(index: -1, fifth: 7, octave: 12, offset: 0, notes: notes, keyOffsets: keyOffsets);
  }
  return TuningInfo(index: index!, fifth: fifth, octave: octave, offset: offset!, color: color, notes: notes, keyOffsets: keyOffsets, base: base);
}

// ---------------------------------------------------------------------------------------------
// quarter-tone notation

const _letterPc = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
const _letters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];

/// Below this fraction of a quarter tone a deviation is not drawn (about 5 cents).
const double qtDrawThreshold = 0.1;

/// A pitch named by its nearest quarter tone: letter, octave, the accidental as a continuous number
/// of quarter tones above the natural letter (positive sharp), and how it relates to 12-TET.
class QtLabel {
  final String letter;
  final int octave;

  /// The accidental in quarter tones (continuous), e.g. 1.55 for 31-TET C♯ (one full stroke and a
  /// 55% stroke).
  final double qt;

  /// The 12-TET deviation of the pitch from the spelled note it is drawn on, in cents.
  final double centsFrom12;

  /// True when the letter is not the key's spelled letter (the accidental would exceed ±3½ quarter tones).
  final bool respelled;
  const QtLabel({required this.letter, required this.octave, required this.qt, required this.centsFrom12, this.respelled = false});

  /// The nearest quarter tone (whole number of quarter tones).
  int get nearest => qt.round();

  /// The remaining deviation as a fraction of a quarter tone, in [-0.5, 0.5].
  double get frac => qt - nearest;

  /// The remaining deviation in cents, in [-25, 25].
  double get fracCents => frac * 50;

  /// The accidental's name: 'half-sharp', 'sharp', 'sesquisharp', 'double sharp' and the flats.
  String get accidentalName => accidentalNameOf(nearest);

  /// 'C♯4', 'D half-flat 4' style name of the nearest quarter tone.
  String get name {
    final acc = accidentalText(nearest);
    return '$letter$acc$octave';
  }

  @override
  String toString() => '$letter${accidentalText(nearest)}$octave ${frac >= 0 ? '+' : ''}${frac.toStringAsFixed(2)} qt';

  static String accidentalNameOf(int n) => switch (n) {
    0 => 'natural',
    1 => 'half-sharp',
    2 => 'sharp',
    3 => 'sesquisharp',
    4 => 'double sharp',
    -1 => 'half-flat',
    -2 => 'flat',
    -3 => 'sesquiflat',
    -4 => 'double flat',
    _ => n > 0 ? '$n quarter tones sharp' : '${-n} quarter tones flat',
  };

  /// Compact text of a quarter-tone accidental (Unicode where it exists, words otherwise).
  static String accidentalText(int n) => switch (n) {
    0 => '',
    1 => '\u{1D132}', // quarter tone sharp
    2 => '♯',
    3 => '\u{1D130}♯', // sharp up + sharp, the common text stand-in
    4 => '\u{1D12A}',
    -1 => '\u{1D133}', // quarter tone flat
    -2 => '♭',
    -3 => '\u{1D133}♭',
    -4 => '𝄫',
    _ => accidentalNameOf(n),
  };
}

/// Names [pitch] (MIDI-like semitones) on [letter]: the accidental is the distance to the natural
/// letter nearest the pitch, in quarter tones. [nominalMidi]: the spelled note's 12-TET pitch, for
/// the cents readout (default: the natural plus the rounded accidental). Letters are respelled only
/// when the accidental would pass ±3½ quarter tones (5-TET, 7-TET).
QtLabel quarterToneLabel(double pitch, String letter, {int? nominalMidi}) {
  QtLabel on(String l, bool respelled) {
    final pc = _letterPc[l]!;
    final k = ((pitch - pc) / 12).round();
    final natural = pc + 12 * k;
    final qt = (pitch - natural) * 2;
    final nominal = nominalMidi ?? (natural + (qt / 2).round());
    return QtLabel(letter: l, octave: k - 1, qt: qt, centsFrom12: (pitch - nominal) * 100, respelled: respelled);
  }

  final first = on(letter, false);
  if (first.qt.abs() <= 3.6) return first;
  QtLabel best = first;
  for (final l in _letters) {
    final c = on(l, true);
    if (c.qt.abs() < best.qt.abs() - 1e-9) best = c;
  }
  return QtLabel(letter: best.letter, octave: best.octave, qt: best.qt, centsFrom12: first.centsFrom12, respelled: true);
}

/// Signed cents, rounded: '+16', '−23', '0'.
String centsText(double cents, {int decimals = 0}) {
  final r = cents.abs().toStringAsFixed(decimals);
  if (double.parse(r) == 0) return '0';
  return '${cents < 0 ? '−' : '+'}$r';
}
