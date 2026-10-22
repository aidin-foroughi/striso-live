// Harmony for the Striso: scales, chord names, roman numerals and functions, key finding.
// Port of tools/app/js/harmony.js. Notes are spelled: the Striso's columns are a line of fifths,
// so a key knows whether it is D# or Eb. A tonal pitch class (tpc) is a position on the line of
// fifths with C = 0, G = 1, F = -1, D = 2, Bb = -2, F# = 6; its pitch class is tpc * 7 mod 12.

import 'dart:math' as math;

int mod(int a, int n) => ((a % n) + n) % n;
int pcOf(int tpc) => mod(tpc * 7, 12);

const _letters = 'FCGDAEB';
const _letterTpc = {'F': -1, 'C': 0, 'G': 1, 'D': 2, 'A': 3, 'E': 4, 'B': 5};
const _letterPc = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};

String accidentalText(int n, {bool ascii = false}) {
  if (n > 0) return n == 2 ? (ascii ? 'x' : '\u{1D12A}') : (ascii ? '#' : '♯') * n;
  if (n < 0) return (ascii ? 'b' : '♭') * -n;
  return '';
}

String tpcName(int tpc, {bool ascii = false}) {
  final acc = ((tpc + 1) / 7).floor();
  return _letters[mod(tpc + 1, 7)] + accidentalText(acc, ascii: ascii);
}

/// A spelled note: tpc and (optional) MIDI number.
class SNote {
  final int tpc;
  final int? midi;
  const SNote(this.tpc, [this.midi]);
  @override
  String toString() => '${tpcName(tpc)}${midi ?? ''}';
}

/// 'Bb4', 'F#3', 'Cx5', 'Eb' (octave optional).
SNote parseNote(String s) {
  final m = RegExp(r'^([A-G])((?:bb|b|#|x|♭|♯)*)(-?\d+)?$').firstMatch(s.trim());
  if (m == null) throw FormatException("bad note '$s'");
  var acc = 0;
  for (final ch in m[2]!.split('')) {
    acc += (ch == '#' || ch == '♯')
        ? 1
        : ch == 'x'
        ? 2
        : -1;
  }
  final tpc = _letterTpc[m[1]!]! + 7 * acc;
  final midi = m[3] == null ? null : _letterPc[m[1]!]! + acc + (int.parse(m[3]!) + 1) * 12;
  return SNote(tpc, midi);
}

List<SNote> notes(String s) => s.trim().split(RegExp(r'\s+')).map(parseNote).toList();

// ---------------------------------------------------------------------------------------------
// scales

const List<int> _major = [0, 2, 4, -1, 1, 3, 5];
const List<int> _natMinor = [0, 2, -3, -1, 1, -4, -2];

class ScaleDef {
  final String label, key;
  final List<int>? fifths;
  final String? ref; // 'major' | 'minor' | null
  final int sig;
  final bool raise;
  const ScaleDef(this.label, this.key, this.fifths, this.ref, this.sig, {this.raise = false});
}

const Map<String, ScaleDef> scales = {
  'off': ScaleDef('Off', '', null, null, 0),
  'major': ScaleDef('Major', 'major', _major, 'major', 0),
  'minor': ScaleDef('Natural minor', 'minor', _natMinor, 'minor', -3, raise: true),
  'harmonic': ScaleDef('Harmonic minor', 'harmonic minor', [0, 2, -3, -1, 1, -4, 5], 'minor', -3, raise: true),
  'melodic': ScaleDef('Melodic minor', 'melodic minor', [0, 2, -3, -1, 1, 3, 5], 'minor', -3, raise: true),
  'dorian': ScaleDef('Dorian', 'dorian', [0, 2, -3, -1, 1, 3, -2], 'minor', -2),
  'phrygian': ScaleDef('Phrygian', 'phrygian', [0, -5, -3, -1, 1, -4, -2], 'minor', -4),
  'lydian': ScaleDef('Lydian', 'lydian', [0, 2, 4, 6, 1, 3, 5], 'major', 1),
  'mixolydian': ScaleDef('Mixolydian', 'mixolydian', [0, 2, 4, -1, 1, 3, -2], 'major', -1),
  'locrian': ScaleDef('Locrian', 'locrian', [0, -5, -3, -1, -6, -4, -2], 'minor', -5),
  'majpent': ScaleDef('Major pentatonic', 'major pentatonic', [0, 2, 4, 1, 3], 'major', 0),
  'minpent': ScaleDef('Minor pentatonic', 'minor pentatonic', [0, -3, -1, 1, -2], 'minor', -3, raise: true),
  'blues': ScaleDef('Blues', 'blues', [0, -3, -1, -6, 1, -2], 'minor', -3, raise: true),
  'whole': ScaleDef('Whole tone', 'whole tone', [0, 2, 4, 6, 8, 10], null, 0),
  'dimhw': ScaleDef('Diminished (half-whole)', 'half-whole diminished', [0, -5, -3, 4, 6, 1, 3, -2], null, 0),
  'dimwh': ScaleDef('Diminished (whole-half)', 'whole-half diminished', [0, 2, -3, -1, -6, -4, 3, 5], null, 0),
};
const List<String> scaleOrder = [
  'off',
  'major',
  'minor',
  'harmonic',
  'melodic',
  'dorian',
  'phrygian',
  'lydian',
  'mixolydian',
  'locrian',
  'majpent',
  'minpent',
  'blues',
  'whole',
  'dimhw',
  'dimwh',
];

/// The tonic spelling with the smaller key signature (Bb major, not A# major); flats on a tie.
int spellTonic(int pc, [String type = 'major']) {
  final sig = scales[type]?.sig ?? 0;
  final t0 = mod(pc * 7, 12);
  final cands = [t0, t0 - 12]
    ..sort((a, b) {
      final c = (a + sig).abs() - (b + sig).abs();
      return c != 0 ? c : (a + sig) - (b + sig);
    });
  return cands.first;
}

class MusicKey {
  final int pc, tonic;
  final String type, name;
  final String? ref;
  final bool raise;
  final Set<int> tpcs, pcs, pool;
  final List<int> degreeFifths, degreePcs;
  const MusicKey({
    required this.pc,
    required this.type,
    required this.tonic,
    required this.ref,
    required this.raise,
    required this.tpcs,
    required this.pcs,
    required this.degreeFifths,
    required this.degreePcs,
    required this.pool,
    required this.name,
  });
}

MusicKey? makeKey(int pc, String type) {
  final sc = scales[type];
  if (sc == null || sc.fifths == null) return null;
  final fifths = sc.fifths!;
  final tonic = spellTonic(pc, type);
  // the minor family reads against natural minor with the raised 6th and 7th also diatonic; modes
  // read against their own degrees
  final degreeFifths = sc.raise
      ? _natMinor
      : fifths.length == 7
      ? fifths
      : sc.ref == 'minor'
      ? _natMinor
      : _major;
  final degreePcs = [for (final f in degreeFifths) pcOf(tonic + f)];
  final pool = {...degreePcs};
  if (sc.raise) pool.addAll([pcOf(tonic + 5), pcOf(tonic + 3)]);
  for (final f in fifths) {
    pool.add(pcOf(tonic + f));
  }
  return MusicKey(
    pc: mod(pc, 12),
    type: type,
    tonic: tonic,
    ref: sc.ref,
    raise: sc.raise,
    tpcs: {for (final f in fifths) tonic + f},
    pcs: {for (final f in fifths) pcOf(tonic + f)},
    degreeFifths: degreeFifths,
    degreePcs: degreePcs,
    pool: pool,
    name: '${tpcName(tonic)} ${sc.key}',
  );
}

enum KeyRelation { none, root, inScale, rootEnharmonic, enharmonic, out }

KeyRelation keyRelation(MusicKey? key, int tpc) {
  if (key == null) return KeyRelation.none;
  if (tpc == key.tonic) return KeyRelation.root;
  if (key.tpcs.contains(tpc)) return KeyRelation.inScale;
  if (pcOf(tpc) == pcOf(key.tonic)) return KeyRelation.rootEnharmonic;
  if (key.pcs.contains(pcOf(tpc))) return KeyRelation.enharmonic;
  return KeyRelation.out;
}

const _solfege = {
  0: 'do',
  1: 'sol',
  2: 're',
  3: 'la',
  4: 'mi',
  5: 'ti',
  -1: 'fa',
  -2: 'te',
  -3: 'me',
  -4: 'le',
  -5: 'ra',
  6: 'fi',
  7: 'di',
  8: 'si',
  9: 'ri',
  10: 'li',
  -6: 'se',
};

String degreeLabel(MusicKey key, int tpc) {
  final d = tpc - key.tonic;
  final deg = mod(d * 4, 7) + 1;
  final acc = (d - _major[deg - 1]) ~/ 7;
  return '${accidentalText(acc)}$deg';
}

String solfege(MusicKey key, int tpc) => _solfege[tpc - key.tonic] ?? degreeLabel(key, tpc);

// ---------------------------------------------------------------------------------------------
// chord types: tones as (semitones, fifths: the usual spelling) above the root

typedef Tone = (int semi, int fifths);
const _R = (0, 0), _m2 = (1, -5), _M2 = (2, 2), _m3 = (3, -3), _A2 = (3, 9), _M3 = (4, 4), _P4 = (5, -1);
const _A4 = (6, 6), _d5 = (6, -6), _P5 = (7, 1), _A5 = (8, 8), _m6 = (8, -4), _M6 = (9, 3), _d7 = (9, -9), _m7 = (10, -2), _M7 = (11, 5);

enum ChordClass { triad, sus, seventh, other }

class RomanStyle {
  final bool upper, maj;
  final String mark, suffix;
  const RomanStyle({required this.upper, this.mark = '', this.maj = false, this.suffix = ''});
}

class ChordType {
  final String id, sym;
  final double cost;
  final ChordClass cls;
  final List<Tone> req, opt;
  final RomanStyle roman;
  const ChordType(this.id, this.sym, this.cost, this.cls, this.req, this.opt, this.roman);
  bool get symmetric => id == 'dim7' || id == 'aug';
}

const List<ChordType> chordTypes = [
  ChordType('maj', '', 0, ChordClass.triad, [_R, _M3, _P5], [], RomanStyle(upper: true)),
  ChordType('min', 'm', 0, ChordClass.triad, [_R, _m3, _P5], [], RomanStyle(upper: false)),
  ChordType('dim', 'dim', 0.3, ChordClass.triad, [_R, _m3, _d5], [], RomanStyle(upper: false, mark: '°')),
  ChordType('aug', 'aug', 0.45, ChordClass.triad, [_R, _M3, _A5], [], RomanStyle(upper: true, mark: '+')),
  ChordType('sus4', 'sus4', 0.8, ChordClass.sus, [_R, _P4, _P5], [], RomanStyle(upper: true, suffix: 'sus4')),
  ChordType('sus2', 'sus2', 0.9, ChordClass.sus, [_R, _M2, _P5], [], RomanStyle(upper: true, suffix: 'sus2')),
  ChordType('7', '7', 1.0, ChordClass.seventh, [_R, _M3, _m7], [_P5], RomanStyle(upper: true)),
  ChordType('maj7', 'maj7', 1.1, ChordClass.seventh, [_R, _M3, _M7], [_P5], RomanStyle(upper: true, maj: true)),
  ChordType('m7', 'm7', 1.0, ChordClass.seventh, [_R, _m3, _m7], [_P5], RomanStyle(upper: false)),
  ChordType('m7b5', 'm7♭5', 1.15, ChordClass.seventh, [_R, _m3, _d5, _m7], [], RomanStyle(upper: false, mark: 'ø')),
  ChordType('dim7', 'dim7', 1.1, ChordClass.seventh, [_R, _m3, _d5, _d7], [], RomanStyle(upper: false, mark: '°')),
  ChordType('mmaj7', 'm(maj7)', 1.6, ChordClass.seventh, [_R, _m3, _M7], [_P5], RomanStyle(upper: false, maj: true)),
  ChordType('aug7', '7♯5', 1.5, ChordClass.seventh, [_R, _M3, _A5, _m7], [], RomanStyle(upper: true, mark: '+')),
  ChordType('augmaj7', 'maj7♯5', 1.8, ChordClass.seventh, [_R, _M3, _A5, _M7], [], RomanStyle(upper: true, mark: '+', maj: true)),
  ChordType('7b5', '7♭5', 1.7, ChordClass.other, [_R, _M3, _d5, _m7], [], RomanStyle(upper: true, suffix: '7♭5')),
  ChordType('7sus4', '7sus4', 1.4, ChordClass.other, [_R, _P4, _m7], [_P5], RomanStyle(upper: true, suffix: '7sus4')),
  ChordType('6', '6', 1.5, ChordClass.other, [_R, _M3, _M6], [_P5], RomanStyle(upper: true, suffix: 'add6')),
  ChordType('m6', 'm6', 1.6, ChordClass.other, [_R, _m3, _M6], [_P5], RomanStyle(upper: false, suffix: 'add6')),
  ChordType('add9', 'add9', 1.6, ChordClass.other, [_R, _M2, _M3], [_P5], RomanStyle(upper: true, suffix: 'add9')),
  ChordType('madd9', 'm(add9)', 1.8, ChordClass.other, [_R, _M2, _m3], [_P5], RomanStyle(upper: false, suffix: 'add9')),
  ChordType('69', '6/9', 2.0, ChordClass.other, [_R, _M2, _M3, _M6], [_P5], RomanStyle(upper: true, suffix: '6/9')),
  ChordType('9', '9', 1.6, ChordClass.other, [_R, _M2, _M3, _m7], [_P5], RomanStyle(upper: true, suffix: '9')),
  ChordType('maj9', 'maj9', 1.7, ChordClass.other, [_R, _M2, _M3, _M7], [_P5], RomanStyle(upper: true, suffix: 'maj9')),
  ChordType('m9', 'm9', 1.7, ChordClass.other, [_R, _M2, _m3, _m7], [_P5], RomanStyle(upper: false, suffix: '9')),
  ChordType('7b9', '7♭9', 1.8, ChordClass.other, [_R, _m2, _M3, _m7], [_P5], RomanStyle(upper: true, suffix: '7♭9')),
  ChordType('7#9', '7♯9', 1.8, ChordClass.other, [_R, _A2, _M3, _m7], [_P5], RomanStyle(upper: true, suffix: '7♯9')),
  ChordType('7#11', '7♯11', 2.0, ChordClass.other, [_R, _M3, _A4, _m7], [_P5, _M2], RomanStyle(upper: true, suffix: '7♯11')),
  ChordType('7b13', '7♭13', 2.1, ChordClass.other, [_R, _M3, _P5, _m6, _m7], [], RomanStyle(upper: true, suffix: '7♭13')),
  ChordType('11', '11', 2.2, ChordClass.other, [_R, _P4, _m7], [_M2, _M3, _P5], RomanStyle(upper: true, suffix: '11')),
  ChordType('m11', 'm11', 2.2, ChordClass.other, [_R, _m3, _P4, _m7], [_M2, _P5], RomanStyle(upper: false, suffix: '11')),
  ChordType('13', '13', 2.0, ChordClass.other, [_R, _M3, _M6, _m7], [_P5, _M2], RomanStyle(upper: true, suffix: '13')),
  ChordType('maj13', 'maj13', 2.3, ChordClass.other, [_R, _M3, _M6, _M7], [_P5, _M2], RomanStyle(upper: true, suffix: 'maj13')),
  ChordType('m13', 'm13', 2.4, ChordClass.other, [_R, _m3, _M6, _m7], [_P5, _M2], RomanStyle(upper: false, suffix: '13')),
];
const _dominantTypes = {'maj', '7', '9', '7b9', '7#9', '7b13', '13'};
const _leadingTypes = {'dim', 'dim7', 'm7b5'};
const _inversionText = ['root position', 'first inversion', 'second inversion', 'third inversion'];

// ---------------------------------------------------------------------------------------------
// intervals (two notes)

const _intervals = {
  0: ('P1', 'unison'),
  1: ('P5', 'perfect fifth'),
  -1: ('P4', 'perfect fourth'),
  2: ('M2', 'major second'),
  -2: ('m7', 'minor seventh'),
  3: ('M6', 'major sixth'),
  -3: ('m3', 'minor third'),
  4: ('M3', 'major third'),
  -4: ('m6', 'minor sixth'),
  5: ('M7', 'major seventh'),
  -5: ('m2', 'minor second'),
  6: ('A4', 'tritone (augmented fourth)'),
  -6: ('d5', 'tritone (diminished fifth)'),
  7: ('A1', 'augmented unison'),
  -7: ('d8', 'diminished octave'),
  8: ('A5', 'augmented fifth'),
  -8: ('d4', 'diminished fourth'),
  9: ('A2', 'augmented second'),
  -9: ('d7', 'diminished seventh'),
  10: ('A6', 'augmented sixth'),
  -10: ('d3', 'diminished third'),
  11: ('A3', 'augmented third'),
  -11: ('d6', 'diminished sixth'),
};
const _intervals12 = [1, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5];

// ---------------------------------------------------------------------------------------------
// results

enum HarmonyKind { note, interval, chord, cluster }

class Roman {
  final int acc;
  final String numeral, mark, suffix;
  final bool maj;
  final List<String> figs;
  final String? applied, special;
  const Roman({
    this.acc = 0,
    this.numeral = '',
    this.mark = '',
    this.maj = false,
    this.figs = const [],
    this.suffix = '',
    this.applied,
    this.special,
  });

  String get text {
    if (special != null) return special!;
    return '${accidentalText(acc)}$numeral$mark${maj ? 'maj' : ''}${figs.join('/')}$suffix${applied != null ? '/$applied' : ''}';
  }
}

class Harmony {
  final HarmonyKind kind;
  String name;
  String long;
  final List<String> notes;
  // note
  final String? degree, solfegeName;
  // interval
  final String? interval;
  // chord
  final int? root, bass;
  final String? type;
  final int inversion;
  final List<int> pcs;
  final String? alt;
  Roman? roman;
  String? func; // 'T' | 'S' | 'D'
  String? funcLabel;
  String? tag; // 'borrowed' | 'secondary' | 'chromatic'

  Harmony({
    required this.kind,
    required this.name,
    this.long = '',
    required this.notes,
    this.degree,
    this.solfegeName,
    this.interval,
    this.root,
    this.bass,
    this.type,
    this.inversion = 0,
    this.pcs = const [],
    this.alt,
  });
}

// ---------------------------------------------------------------------------------------------
// analysis

Harmony? analyze(List<SNote> input, [MusicKey? key]) {
  if (input.isEmpty) return null;
  final indexed = [for (var i = 0; i < input.length; i++) (n: input[i], i: i)];
  indexed.sort((a, b) => (a.n.midi ?? a.i).compareTo(b.n.midi ?? b.i));
  final sorted = [for (final e in indexed) e.n];
  final bass = sorted.first;
  // one spelling per pitch class: the bass's, else the lowest
  final byPc = <int, int>{};
  for (final n in sorted) {
    byPc.putIfAbsent(pcOf(n.tpc), () => n.tpc);
  }
  final spelled = {for (final n in sorted) n.tpc};
  final noteNames = <String>[];
  for (final n in sorted) {
    final s = tpcName(n.tpc);
    if (!noteNames.contains(s)) noteNames.add(s);
  }
  final pcs = byPc.keys.toList();

  if (pcs.length == 1) {
    return Harmony(
      kind: HarmonyKind.note,
      name: tpcName(bass.tpc),
      notes: noteNames,
      degree: key != null ? degreeLabel(key, bass.tpc) : null,
      solfegeName: key != null ? solfege(key, bass.tpc) : null,
    );
  }
  if (pcs.length == 2) {
    final hi = sorted.firstWhere((n) => pcOf(n.tpc) != pcOf(bass.tpc));
    var d = hi.tpc - bass.tpc;
    if (!_intervals.containsKey(d)) d = _intervals12[mod(pcOf(hi.tpc) - pcOf(bass.tpc), 12)];
    final iv = _intervals[d]!;
    final compound = bass.midi != null && hi.midi != null && hi.midi! - bass.midi! > 12;
    return Harmony(
      kind: HarmonyKind.interval,
      name: iv.$1 == 'P5' ? '${tpcName(bass.tpc)}5' : iv.$1,
      interval: iv.$1,
      long: iv.$2 + (compound ? ' (compound)' : ''),
      notes: noteNames,
    );
  }

  // chord: every held pitch class as a candidate root, every chord type
  ({double cost, ChordType type, int rootTpc, int rootPc})? best;
  for (final MapEntry(key: rootPc, value: rootTpc) in byPc.entries) {
    final rel = <int, int>{for (final e in byPc.entries) mod(e.key - rootPc, 12): e.value};
    for (final type in chordTypes) {
      final tones = [...type.req, ...type.opt];
      final semis = {for (final t in tones) t.$1};
      if (!rel.keys.every(semis.contains)) continue;
      if (!type.req.every((t) => rel.containsKey(t.$1))) continue;
      var cost = type.cost + 0.35 * type.opt.where((t) => !rel.containsKey(t.$1)).length;
      if (pcOf(bass.tpc) != rootPc) cost += 1.0;
      final spellWeight = type.symmetric ? 1.2 : 0.12;
      for (final MapEntry(key: s, value: tpc) in rel.entries) {
        final tone = tones.firstWhere((t) => t.$1 == s);
        if (tpc - rootTpc != tone.$2) cost += spellWeight;
      }
      if (key != null) {
        // with a key, an added-sixth chord off the tonic reads better as a seventh chord in
        // inversion (F A C D in C: ii6/5); on the tonic it stays a sixth chord (C6)
        if ((type.id == '6' || type.id == 'm6') && rootPc != pcOf(key.tonic)) cost += 0.6;
        if (!key.pool.contains(rootPc)) cost += 0.25;
        for (final pc in pcs) {
          if (!key.pool.contains(pc)) cost += 0.08;
        }
      }
      if (best == null || cost < best.cost - 1e-9) best = (cost: cost, type: type, rootTpc: rootTpc, rootPc: rootPc);
    }
  }
  if (best == null) return Harmony(kind: HarmonyKind.cluster, name: '?', notes: noteNames, long: 'no common chord');

  final type = best.type, rootTpc = best.rootTpc, rootPc = best.rootPc;
  final bassRel = mod(pcOf(bass.tpc) - rootPc, 12);
  var inversion = 0;
  if (bassRel != 0) {
    inversion = -1;
    if (type.cls == ChordClass.triad || type.cls == ChordClass.seventh) {
      if (bassRel == 3 || bassRel == 4) {
        inversion = 1;
      } else if (bassRel >= 6 && bassRel <= 8) {
        inversion = 2;
      } else if (bassRel >= 9) {
        inversion = 3;
      }
    }
  }
  final slash = bassRel != 0 ? '/${tpcName(bass.tpc)}' : '';
  final chord = Harmony(
    kind: HarmonyKind.chord,
    root: rootTpc,
    bass: bass.tpc,
    type: type.id,
    name: tpcName(rootTpc) + type.sym + slash,
    inversion: inversion,
    long: inversion >= 0 ? _inversionText[inversion] : 'over ${tpcName(bass.tpc)}',
    notes: noteNames,
    pcs: pcs,
    alt: type.id == 'm7b5' ? '${tpcName(rootTpc)}ø7$slash' : null,
  );
  if (key != null) _harmonize(chord, type, key, spelled);
  return chord;
}

List<String> _figuresOf(ChordType type, int inversion) {
  if (type.cls == ChordClass.triad) {
    return const [
          <String>[],
          ['6'],
          ['6', '4'],
        ].elementAtOrNull(inversion) ??
        const [];
  }
  if (type.cls == ChordClass.seventh) {
    return const [
          ['7'],
          ['6', '5'],
          ['4', '3'],
          ['4', '2'],
        ].elementAtOrNull(inversion) ??
        const ['7'];
  }
  return const [];
}

const _numerals = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];

({int deg, int acc}) _degreeOf(MusicKey key, int tpc) {
  final df = key.degreeFifths;
  final minor = key.ref == 'minor';
  ({int deg, int acc}) fix(int d) {
    final deg = mod(d * 4, 7) + 1;
    var acc = (d - df[deg - 1]) ~/ 7;
    if (minor && key.raise && deg == 7 && acc == 1) acc = 0; // leading tone: vii°, not #vii°
    return (deg: deg, acc: acc);
  }

  var d = tpc - key.tonic;
  if (d > 9) d -= 12;
  if (d < -9) d += 12;
  var r = fix(d);
  if (r.acc.abs() > 1) {
    d = mod(mod(pcOf(tpc) - pcOf(key.tonic), 12) * 7, 12);
    if (d > 6) d -= 12;
    r = fix(d);
  }
  return r;
}

({int deg, int acc}) _degreeOfIn(List<int> df, MusicKey key, int tpc) {
  var d = tpc - key.tonic;
  if (d > 9) d -= 12;
  if (d < -9) d += 12;
  final deg = mod(d * 4, 7) + 1;
  return (deg: deg, acc: (d - df[deg - 1]) ~/ 7);
}

String _triadQualityOn(MusicKey key, int deg) {
  final p = key.degreePcs;
  final k = deg - 1;
  if (key.raise && deg == 5) return 'maj'; // harmonic minor V
  final third = mod(p[(k + 2) % 7] - p[k], 12), fifth = mod(p[(k + 4) % 7] - p[k], 12);
  if (third == 4 && fifth == 7) return 'maj';
  if (third == 3 && fifth == 7) return 'min';
  if (third == 3 && fifth == 6) return 'dim';
  return 'aug';
}

const _functionLabel = {'T': 'Tonic', 'S': 'Subdominant', 'D': 'Dominant'};
String _degreeFunction(int deg) => [1, 3, 6].contains(deg) ? 'T' : ([2, 4].contains(deg) ? 'S' : 'D');

void _harmonize(Harmony chord, ChordType type, MusicKey key, Set<int> spelled) {
  final tonicPc = pcOf(key.tonic);
  int rel(int pc) => mod(pc - tonicPc, 12);
  final relSet = {for (final pc in chord.pcs) rel(pc)};
  final bassRel = rel(pcOf(chord.bass!));
  final rootPc = pcOf(chord.root!);
  final figs = _figuresOf(type, chord.inversion);
  Roman plain(int deg, int acc) => Roman(
    acc: acc,
    numeral: type.roman.upper ? _numerals[deg - 1] : _numerals[deg - 1].toLowerCase(),
    mark: type.roman.mark,
    maj: type.roman.maj && type.cls == ChordClass.seventh,
    figs: figs,
    suffix: type.roman.suffix,
  );
  void out(Roman roman, String? fn, [String? label, String? tag]) {
    chord.roman = roman;
    chord.func = fn;
    chord.funcLabel = label ?? (fn != null ? _functionLabel[fn] : null);
    chord.tag = tag;
  }

  String targetRoman(int deg) {
    final q = _triadQualityOn(key, deg);
    final n = q == 'maj' || q == 'aug' ? _numerals[deg - 1] : _numerals[deg - 1].toLowerCase();
    return n +
        (q == 'dim'
            ? '°'
            : q == 'aug'
            ? '+'
            : '');
  }

  // augmented sixths: on the lowered sixth, with the raised fourth spelled as such
  if (bassRel == 8 && relSet.contains(0) && relSet.contains(6) && spelled.contains(key.tonic + 6)) {
    final rest = relSet.where((r) => r != 8 && r != 0 && r != 6).toList();
    final kind = rest.isEmpty
        ? 'It'
        : rest.length == 1 && rest[0] == 2
        ? 'Fr'
        : rest.length == 1 && rest[0] == 3
        ? 'Ger'
        : null;
    if (kind != null) {
      chord.name = '${tpcName(chord.bass!)} $kind+6';
      chord.long =
          'augmented sixth (${kind == 'It'
              ? 'Italian'
              : kind == 'Fr'
              ? 'French'
              : 'German'})';
      return out(Roman(special: '$kind+6'), 'S', 'Predominant (augmented sixth)', 'chromatic');
    }
  }
  // Neapolitan: major triad on the lowered second (spelled flat)
  if (type.id == 'maj' && rel(rootPc) == 1 && chord.root! - key.tonic == -5) {
    if (chord.inversion == 1) return out(const Roman(special: 'N6'), 'S', 'Predominant (Neapolitan)', 'chromatic');
    return out(plain(2, -1), 'S', 'Predominant (Neapolitan)', 'chromatic');
  }
  final dg = _degreeOf(key, chord.root!);
  final diatonic = chord.pcs.every(key.pool.contains);
  if (diatonic) return out(plain(dg.deg, dg.acc), key.ref != null ? _degreeFunction(dg.deg) : null);

  // modal mixture: everything from the parallel minor (in major) or major (in minor)
  bool mixture() {
    if (key.ref == null) return false;
    final parallel = {for (final f in (key.ref == 'major' ? _natMinor : _major)) mod(pcOf(key.tonic + f) - tonicPc, 12)};
    if (!relSet.every(parallel.contains)) return false;
    final md = _degreeOfIn(_major, key, chord.root!);
    final fn = (md.deg == 6 || md.deg == 7) && key.ref == 'major' ? 'S' : _degreeFunction(md.deg);
    final from = key.ref == 'major' ? 'minor' : 'major';
    out(plain(md.deg, key.ref == 'major' ? md.acc : dg.acc), fn, '${_functionLabel[fn]} (borrowed from $from)', 'borrowed');
    return true;
  }

  // a major tonic chord in minor is the borrowed (Picardy) I before it is V of iv
  if (rel(rootPc) == 0 && mixture()) return;

  int? target(int pc) {
    if (!key.degreePcs.contains(pc) || pc == tonicPc) return null;
    final t = key.degreePcs.indexOf(pc) + 1;
    return _triadQualityOn(key, t) == 'dim' ? null : t;
  }

  if (_dominantTypes.contains(type.id)) {
    // the dominant itself with altered tones (V7b9, V7#9 ...)
    if (rel(rootPc) == 7 && key.ref != null) return out(plain(5, 0), 'D');
    final t = target(mod(rootPc - 7, 12));
    if (t != null) {
      return out(
        Roman(
          numeral: 'V',
          figs: figs,
          suffix: type.roman.suffix.isNotEmpty && type.cls == ChordClass.other ? type.roman.suffix : '',
          applied: targetRoman(t),
        ),
        'D',
        'Dominant of ${targetRoman(t)}',
        'secondary',
      );
    }
  }
  if (_leadingTypes.contains(type.id)) {
    final t = target(mod(rootPc + 1, 12));
    if (t != null) {
      return out(
        Roman(numeral: 'vii', mark: type.roman.mark, figs: figs, applied: targetRoman(t)),
        'D',
        'Leading-tone chord of ${targetRoman(t)}',
        'secondary',
      );
    }
  }
  if (mixture()) return;
  out(plain(dg.deg, dg.acc), null, 'Chromatic', 'chromatic');
}

// ---------------------------------------------------------------------------------------------
// key finding: Krumhansl-Kessler profiles against a decaying pitch-class histogram

const _kkMajor = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const _kkMinor = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

double _correlation(List<double> a, List<double> b) {
  final n = a.length;
  final ma = a.reduce((s, x) => s + x) / n, mb = b.reduce((s, x) => s + x) / n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var k = 0; k < n; k++) {
    num += (a[k] - ma) * (b[k] - mb);
    da += (a[k] - ma) * (a[k] - ma);
    db += (b[k] - mb) * (b[k] - mb);
  }
  return da != 0 && db != 0 ? num / math.sqrt(da * db) : 0;
}

class KeyEstimate {
  final int pc, tonic;
  final String mode, name;
  final double score;
  const KeyEstimate(this.pc, this.mode, this.score, this.tonic, this.name);
}

class KeyFinder {
  final double halfLife;
  final hist = List<double>.filled(12, 0);
  KeyFinder([this.halfLife = 15]);

  /// weights: (pc, weight); dt in seconds.
  void add(List<(int, double)> weights, double dt) {
    final decay = math.pow(0.5, dt / halfLife).toDouble();
    for (var k = 0; k < 12; k++) {
      hist[k] *= decay;
    }
    for (final (pc, w) in weights) {
      hist[mod(pc, 12)] += w * dt;
    }
  }

  double get total => hist.fold(0.0, (s, x) => s + x);

  KeyEstimate? estimate() {
    if (total <= 0) return null;
    (int, String, double)? best;
    for (var pc = 0; pc < 12; pc++) {
      final rot = [for (var k = 0; k < 12; k++) hist[mod(k + pc, 12)]];
      for (final (mode, prof) in [('major', _kkMajor), ('minor', _kkMinor)]) {
        final r = _correlation(rot, prof);
        if (best == null || r > best.$3) best = (pc, mode, r);
      }
    }
    final tonic = spellTonic(best!.$1, best.$2);
    return KeyEstimate(best.$1, best.$2, best.$3, tonic, '${tpcName(tonic)} ${best.$2}');
  }

  void clear() => hist.fillRange(0, 12, 0);
}
