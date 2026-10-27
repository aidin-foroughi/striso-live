// Harmony: scales, chord names, roman numerals and functions, key finding.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

MusicKey key(String s) {
  final parts = s.split(' ');
  final type = const {
    'major': 'major',
    'minor': 'minor',
    'harmonic minor': 'harmonic',
    'melodic minor': 'melodic',
    'dorian': 'dorian',
  }[parts.sublist(1).join(' ')]!;
  return makeKey(pcOf(parseNote(parts[0]).tpc), type)!;
}

// notes without octave numbers are placed upwards from octave 4 in the order given
List<SNote> placed(String str) {
  var last = -1 << 30;
  return str.trim().split(RegExp(r'\s+')).map((s) {
    if (RegExp(r'\d$').hasMatch(s)) {
      final n = parseNote(s);
      last = n.midi!;
      return n;
    }
    final n = parseNote('${s}4');
    var midi = n.midi!;
    while (midi <= last) {
      midi += 12;
    }
    last = midi;
    return SNote(n.tpc, midi);
  }).toList();
}

Harmony A(String str, [String? k]) => analyze(placed(str), k != null ? key(k) : null)!;
String name(String str, [String? k]) => A(str, k).name;
String roman(String str, [String? k]) => A(str, k).roman!.text;

const roots = ['C', 'G', 'D', 'A', 'E', 'B', 'F#', 'Db', 'Ab', 'Eb', 'Bb', 'F'];
const qualities = {
  'maj': [0, 4, 1],
  'min': [0, -3, 1],
  'dim': [0, -3, -6],
  'aug': [0, 4, 8],
  '7': [0, 4, 1, -2],
  'maj7': [0, 4, 1, 5],
  'm7': [0, -3, 1, -2],
  'm7b5': [0, -3, -6, -2],
  'dim7': [0, -3, -6, -9],
  'mmaj7': [0, -3, 1, 5],
  'aug7': [0, 4, 8, -2],
};
int semi(int f) => mod(f * 7, 12);

List<SNote> build(int rootTpc, List<int> fifths, int inversion) {
  final root = 60 + semi(rootTpc) - 12;
  return [for (final (k, f) in fifths.indexed) SNote(rootTpc + f, root + semi(f) + (k < inversion ? 12 : 0))];
}

void main() {
  test('spelling on the line of fifths', () {
    expect(tpcName(0), 'C');
    expect(tpcName(6), 'F♯');
    expect(tpcName(-2), 'B♭');
    expect(tpcName(-9), 'B♭♭');
    expect(tpcName(-10), 'E♭♭');
    expect(tpcName(13), 'F𝄪');
    final bb = parseNote('Bb3');
    expect([bb.tpc, bb.midi], [-2, 58]);
    final cs = parseNote('C#4');
    expect([cs.tpc, cs.midi], [7, 61]);
    final ebb = parseNote('Ebb4');
    expect([ebb.tpc, ebb.midi], [-10, 62]);
    expect(pcOf(-2), 10);
  });

  test('key spelling follows the smaller signature', () {
    String sp(int pc, String t) => tpcName(spellTonic(pc, t));
    expect(sp(10, 'major'), 'B♭');
    expect(sp(3, 'major'), 'E♭');
    expect(sp(8, 'major'), 'A♭');
    expect(sp(11, 'major'), 'B');
    expect(sp(1, 'minor'), 'C♯');
    expect(sp(8, 'minor'), 'G♯');
    expect(sp(10, 'minor'), 'B♭');
    expect(sp(6, 'minor'), 'F♯');
    expect(sp(2, 'dorian'), 'D');
    expect(sp(1, 'mixolydian'), 'D♭');
    expect(key('Bb major').name, 'B♭ major');
  });

  test('scales: every type spells 5 to 8 distinct pitch classes, relations and degrees', () {
    for (final t in scaleOrder.sublist(1)) {
      final k = makeKey(0, t)!;
      expect(k.pcs.length, scales[t]!.fifths!.length, reason: t);
    }
    final bb = key('Bb major');
    expect(keyRelation(bb, -2), KeyRelation.root);
    expect(keyRelation(bb, -3), KeyRelation.inScale);
    expect(keyRelation(bb, 9), KeyRelation.enharmonic);
    expect(keyRelation(bb, 4), KeyRelation.out);
    final c = key('C major');
    expect(degreeLabel(c, -3), '♭3');
    expect(degreeLabel(c, 6), '♯4');
    expect(degreeLabel(c, 1), '5');
    expect([0, 2, 4, -1, 1, 3, 5, -3, 6, -2].map((t) => solfege(c, t)), ['do', 're', 'mi', 'fa', 'sol', 'la', 'ti', 'me', 'fi', 'te']);
  });

  test('all triad and seventh qualities, all roots, all inversions: names', () {
    var n = 0;
    for (final r in roots) {
      final rt = parseNote(r).tpc;
      for (final MapEntry(key: q, value: fifths) in qualities.entries) {
        final sym = chordTypes.firstWhere((t) => t.id == q).sym;
        for (var inv = 0; inv < fifths.length; inv++) {
          final ch = analyze(build(rt, fifths, inv))!;
          final bass = tpcName(rt + fifths[inv]);
          var want = '${tpcName(rt)}$sym${inv > 0 ? '/$bass' : ''}';
          if (inv == 1 && q == 'm7') want = '${bass}6';
          if (inv == 1 && q == 'm7b5') want = '${bass}m6';
          expect(ch.name, want, reason: '$r $q inversion $inv');
          if (want.startsWith(tpcName(rt))) expect(ch.inversion, inv, reason: '$r $q inversion $inv');
          n++;
        }
      }
    }
    expect(n, 12 * (4 * 3 + 7 * 4));
  });

  test('figured bass for triads and sevenths in C major', () {
    const cases = {
      'C E G': 'I',
      'E G C': 'I6',
      'G C E': 'I6/4',
      'G B D F': 'V7',
      'B D F G': 'V6/5',
      'D F G B': 'V4/3',
      'F G B D': 'V4/2',
      'B D F A': 'viiø7',
      'D F A B': 'viiø6/5',
      'F A B D': 'viiø4/3',
      'F A C E': 'IVmaj7',
      'A C E F': 'IVmaj6/5',
      'C E G B': 'Imaj7',
      'D F A C': 'ii7',
    };
    cases.forEach((ch, want) => expect(roman(ch, 'C major'), want, reason: ch));
  });

  test('diatonic triads and functions in major and minor', () {
    final maj = ['C E G', 'D F A', 'E G B', 'F A C', 'G B D', 'A C E', 'B D F'].map((c) => A(c, 'C major')).toList();
    expect(maj.map((c) => c.roman!.text), ['I', 'ii', 'iii', 'IV', 'V', 'vi', 'vii°']);
    expect(maj.map((c) => c.func), ['T', 'S', 'T', 'S', 'D', 'T', 'D']);
    final min = ['A C E', 'B D F', 'C E G', 'D F A', 'E G B', 'E G# B', 'F A C', 'G B D', 'G# B D', 'D F# A'].map((c) => A(c, 'A minor'));
    expect(min.map((c) => c.roman!.text), ['i', 'ii°', 'III', 'iv', 'v', 'V', 'VI', 'VII', 'vii°', 'IV']);
    expect(roman('E G# B D', 'A minor'), 'V7');
    expect(roman('G# B D F', 'A minor'), 'vii°7');
    expect(roman('B D F G#', 'A minor'), 'vii°6/5');
    expect(roman('B D F A', 'A minor'), 'iiø7');
    expect(roman('F# A C', 'A minor'), '♯vi°');
    expect(A('E G# B D', 'A minor').func, 'D');
    expect(roman('B D F#', 'D dorian'), 'vi');
    expect(roman('G B D', 'D dorian'), 'IV');
  });

  test('every minor variant reads against natural minor with the raised 6th and 7th diatonic', () {
    for (final k in ['A minor', 'A harmonic minor', 'A melodic minor']) {
      final got = [
        'A C E',
        'C E G',
        'G B D F',
        'E G# B D',
        'G# B D F',
        'E G B',
        'F A C',
        'D F A',
        'C E G#',
        'B D# F# A',
        'C E G Bb',
        'D F# A',
      ].map((c) => roman(c, k));
      expect(got, ['i', 'III', 'VII7', 'V7', 'vii°7', 'v', 'VI', 'iv', 'III+', 'V7/V', 'V7/VI', 'IV'], reason: k);
    }
  });

  test('secondary dominants and leading-tone chords', () {
    const c = [
      ('D F# A', 'V/V'),
      ('D F# A C', 'V7/V'),
      ('F# A C D', 'V6/5/V'),
      ('A C# E G', 'V7/ii'),
      ('E G# B D', 'V7/vi'),
      ('B D# F# A', 'V7/iii'),
      ('C E G Bb', 'V7/IV'),
      ('E G# B', 'V/vi'),
      ('F# A C Eb', 'vii°7/V'),
      ('F# A C E', 'viiø7/V'),
      ('C# E G Bb', 'vii°7/ii'),
      ('G# B D F', 'vii°7/vi'),
      ('D F# A C E', 'V9/V'),
    ];
    for (final (ch, want) in c) {
      final r = A(ch, 'C major');
      expect(r.roman!.text, want, reason: ch);
      expect(r.func, 'D', reason: ch);
    }
    expect(A('D F# A C', 'C major').funcLabel, 'Dominant of V');
    const m = [('B D# F# A', 'V7/V'), ('A C# E G', 'V7/iv'), ('C E G Bb', 'V7/VI'), ('D# F# A C', 'vii°7/V'), ('G B D F', 'VII7')];
    for (final (ch, want) in m) {
      expect(roman(ch, 'A minor'), want, reason: ch);
    }
    expect(roman('D F# A C', 'A minor'), 'IV7');
    expect(roman('F# A# C#', 'C major'), isNot('V/vii°'));
    expect(roman('G B D F Ab', 'C major'), 'V7♭9');
    expect(A('G B D F Ab', 'C major').func, 'D');
  });

  test('modal mixture, Neapolitan and augmented sixths', () {
    const k = 'C major';
    expect(roman('Ab C Eb', k), '♭VI');
    expect(roman('Bb D F', k), '♭VII');
    expect(roman('Eb G Bb', k), '♭III');
    expect(roman('F Ab C', k), 'iv');
    expect(roman('D F Ab', k), 'ii°');
    expect(A('Ab C Eb', k).tag, 'borrowed');
    expect(A('Ab C Eb', k).func, 'S');
    expect(A('Eb G Bb', k).func, 'T');
    expect(roman('C E G', 'A minor'), 'III');
    expect(roman('A C# E', 'A minor'), 'I');
    expect(A('A C# E', 'A minor').tag, 'borrowed');
    expect(roman('F Ab Db', k), 'N6');
    expect(A('F Ab Db', k).func, 'S');
    expect(roman('Db F Ab', k), '♭II');
    expect(roman('C# E# G#', k), '♯I', reason: 'spelled C#: not a Neapolitan');
    expect(roman('Ab C Eb F#', k), 'Ger+6');
    expect(name('Ab C Eb F#', k), 'A♭ Ger+6');
    expect(roman('Ab C F#', k), 'It+6');
    expect(roman('Ab C D F#', k), 'Fr+6');
    expect(roman('F A C D#', 'A minor'), 'Ger+6');
    expect(roman('F A D#', 'A minor'), 'It+6');
    expect(name('Ab C Eb Gb', k), 'A♭7');
    expect(roman('Ab C Eb Gb', k), '♭VI7');
    expect(roman('Ab C Eb F#', k), isNot(roman('Ab C Eb Gb', k)));
  });

  test('omitted fifths, doubled notes, wide voicings', () {
    expect(name('C E Bb'), 'C7');
    expect(name('C E B'), 'Cmaj7');
    expect(name('C Eb Bb'), 'Cm7');
    expect(name('G3 B3 F4', 'C major'), 'G7');
    expect(roman('G3 B3 F4', 'C major'), 'V7');
    expect(name('C3 C4 E4 G4 C5 E5'), 'C');
    expect(name('E2 C4 G4 C5'), 'C/E');
    expect(roman('E2 C4 G4 C5', 'C major'), 'I6');
    expect(name('G2 D4 B4 F5 G5'), 'G7');
    expect(A('C E Bb').long, 'root position');
  });

  test('ambiguous sets: the bass, then the key decides', () {
    expect(name('C E G A'), 'C6');
    expect(name('A3 C4 E4 G4'), 'Am7');
    expect(name('C E G A', 'C major'), 'C6');
    expect(roman('C E G A', 'C major'), 'Iadd6');
    expect(name('C E G A', 'A minor'), 'Am7/C');
    expect(roman('C E G A', 'A minor'), 'i6/5');
    expect(name('F A C D'), 'F6');
    expect(roman('F A C D', 'C major'), 'ii6/5');
    expect(roman('D F A B', 'A minor'), 'iiø6/5');
    expect(name('D F A B', 'A minor'), 'Bm7♭5/D');
    expect(name('B D F Ab'), 'Bdim7');
    expect(name('D F Ab B'), 'Bdim7/D');
    expect(name('D F Ab Cb'), 'Ddim7');
    expect(name('C E G#'), 'Caug');
    expect(name('E G# C'), 'Caug/E');
    expect(name('E G# B#'), 'Eaug');
    expect(roman('G# B D F', 'A minor'), 'vii°7');
    expect(roman('B D F G#', 'A minor'), 'vii°6/5');
  });

  test('suspended, added, extended and altered chords', () {
    const want = {
      'C D G': 'Csus2',
      'C F G': 'Csus4',
      'C F G Bb': 'C7sus4',
      'C F Bb': 'C7sus4',
      'C E G A': 'C6',
      'C Eb G A': 'Cm6',
      'C E G D5': 'Cadd9',
      'C Eb G D5': 'Cm(add9)',
      'C E G A D5': 'C6/9',
      'C E G Bb D5': 'C9',
      'C E G B D5': 'Cmaj9',
      'C Eb G Bb D5': 'Cm9',
      'C E G Bb Db5': 'C7♭9',
      'C E G Bb D#5': 'C7♯9',
      'C E G Bb F#5': 'C7♯11',
      'C E G Bb Ab5': 'C7♭13',
      'C E Bb D5 F5': 'C11',
      'C Eb G Bb F5': 'Cm11',
      'C E G Bb A5': 'C13',
      'C E G B A5': 'Cmaj13',
      'C E G# Bb': 'C7♯5',
      'C E Gb Bb': 'C7♭5',
      'C E G# B': 'Cmaj7♯5',
      'C Eb G B': 'Cm(maj7)',
      'C Eb Gb Bbb': 'Cdim7',
      'C Eb Gb': 'Cdim',
      'C Eb Gb Bb': 'Cm7♭5',
    };
    want.forEach((ch, n) => expect(name(ch), n, reason: ch));
    expect(A('C Eb Gb Bb').alt, 'Cø7');
    expect(roman('C E G Bb D5', 'F major'), 'V9');
  });

  test('one and two notes', () {
    final one = A('D4', 'C major');
    expect([one.kind, one.name, one.degree, one.solfegeName], [HarmonyKind.note, 'D', '2', 're']);
    expect(A('D3 D4').kind, HarmonyKind.note, reason: 'octaves are one pitch class');
    List<String> iv(String s) {
      final r = A(s);
      return [r.name, r.long];
    }

    expect(iv('C4 E4'), ['M3', 'major third']);
    expect(iv('C4 Eb4'), ['m3', 'minor third']);
    expect(iv('C4 D#4'), ['A2', 'augmented second']);
    expect(iv('C4 G4'), ['C5', 'perfect fifth']);
    expect(iv('G3 C4'), ['P4', 'perfect fourth']);
    expect(iv('B3 F4'), ['d5', 'tritone (diminished fifth)']);
    expect(iv('F4 B4'), ['A4', 'tritone (augmented fourth)']);
    expect(iv('C4 E5'), ['M3', 'major third (compound)']);
  });

  test('clusters with no common name say so', () {
    final r = A('C Db D Eb');
    expect(r.kind, HarmonyKind.cluster);
    expect(r.notes, ['C', 'D♭', 'D', 'E♭']);
  });

  test('key finding with Krumhansl profiles', () {
    final kf = KeyFinder(10);
    void feed(String str) {
      for (final n in str.split(' ')) {
        kf.add([(pcOf(parseNote(n).tpc), 1.0)], 0.5);
      }
    }

    for (var k = 0; k < 6; k++) {
      feed('C D E F G A B C E G C');
    }
    expect(kf.estimate()!.name, 'C major');
    kf.clear();
    for (var k = 0; k < 6; k++) {
      feed('A B C D E F G# A C E A E');
    }
    expect(kf.estimate()!.name, 'A minor');
    kf.clear();
    for (var k = 0; k < 6; k++) {
      feed('Bb C D Eb F G A Bb D F Bb');
    }
    expect(kf.estimate()!.name, 'B♭ major');
    expect(KeyFinder().estimate(), isNull);
  });
  group('scale library', () {
    String spelled(String id, int pc) {
      final k = makeKey(pc, id)!;
      return [for (final f in scales[id]!.fifths!) tpcName(k.tonic + f)].join(' ');
    }

    test('spellings in their keys, sharps or flats by the smaller signature', () {
      expect(spelled('phrygdom', 6), 'F♯ G A♯ B C♯ D E');
      expect(spelled('neapmin', 3), 'E♭ F♭ G♭ A♭ B♭ C♭ D');
      expect(spelled('altered', 2), 'D E♭ F G♭ A♭ B♭ C');
      expect(spelled('bebopdom', 0), 'C D E F G A B♭ B');
      expect(spelled('hungmin', 9), 'A B C D♯ E F G♯');
      expect(spelled('lyddom', 7), 'G A B C♯ D E F');
      expect(spelled('harmmajor', 10), 'B♭ C D E♭ F G♭ A');
      expect(spelled('bh6dim', 0), 'C D E F G A♭ A B');
      expect(spelled('hirajoshi', 4), 'E F♯ G B C');
      expect(spelled('ultralocrian', 2), 'D E♭ F G♭ A♭ B♭ C♭');
      expect(spelled('enigmatic', 0), 'C D♭ E F♯ G♯ A♯ B');
      expect(spelled('dorian4', 2), 'D E F G♯ A B C');
      expect(spelled('neapmaj', 7), 'G A♭ B♭ C D E F♯');
      expect(spelled('bebopdor', 2), 'D E F F♯ G A B C');
      expect(spelled('insen', 4), 'E F A B D');
      expect(spelled('augmented', 0), 'C E♭ E G G♯ B');
      expect(spelled('dblharm', 4), 'E F G♯ A B C D♯');
      expect(spelled('chromatic', 0).split(' ').length, 12);
    });

    test('formulas, groups and every scale distinct and numbered', () {
      expect(scaleFormula('harmonic'), '1 2 ♭3 4 5 ♭6 ♮7');
      expect(scaleFormula('lydaug'), '1 2 3 ♯4 ♯5 6 7');
      expect(scaleFormula('ultralocrian'), '1 ♭2 ♭3 ♭4 ♭5 ♭6 𝄫7');
      expect(scaleFormula('bh7b5dim'), '1 2 3 4 ♭5 ♭6 ♭7 ♮7');
      expect(scales.length, greaterThanOrEqualTo(60));
      for (final (g, ids) in scaleGroups) {
        for (final id in ids) {
          expect(scales.containsKey(id), isTrue, reason: '$g: $id');
        }
      }
      for (final id in scaleOrder.skip(1)) {
        final f = scales[id]!.fifths!;
        expect({for (final x in f) mod(x * 7, 12)}.length, f.length, reason: '$id has two notes on one pitch');
        expect(f.first, 0, reason: id);
        for (var pc = 0; pc < 12; pc++) {
          final k = makeKey(pc, id)!;
          expect(k.degreeFifths.length, 7, reason: id);
        }
      }
    });

    test('every chord in every scale and key gets a reading, never a crash', () {
      const chords = ['C E G', 'D F A C', 'G B D F', 'F A C', 'B D F', 'E G# B', 'Db F Ab', 'Ab C Eb F#', 'C Eb Gb Bbb', 'C D'];
      for (final id in scaleOrder.skip(1)) {
        for (final pc in [0, 3, 6, 9, 10]) {
          final k = makeKey(pc, id)!;
          for (final ch in chords) {
            final a = analyze(placed(ch), k);
            expect(a, isNotNull, reason: '$id $pc $ch');
            if (a!.kind == HarmonyKind.chord) expect(a.roman, isNotNull, reason: '$id $pc $ch');
          }
        }
      }
    });

    test('Barry Harris: alternate tones of the sixth chord and the diminished chord', () {
      final c = makeKey(0, 'bh6dim')!;
      expect(barryHarrisText(c), 'C6 (C E G A) + B°7 (B D F A♭)');
      expect(barryHarrisRole(c, parseNote('E').tpc), BarryHarrisRole.chord);
      expect(barryHarrisRole(c, parseNote('Ab').tpc), BarryHarrisRole.dim);
      expect(barryHarrisRole(c, parseNote('F#').tpc), isNull);
      expect(barryHarrisText(makeKey(9, 'bhm6dim')), 'Am6 (A C E F♯) + G♯°7 (G♯ B D F)');
      expect(barryHarrisText(makeKey(7, 'bh7dim')), 'G7 (G B D F) + F♯°7 (F♯ A C E♭)');
      expect(barryHarrisText(makeKey(0, 'bh7b5dim')), 'C7♭5 (C E G♭ B♭) + B°7 (B D F A♭)');
      expect(barryHarrisText(makeKey(0, 'major')), isNull);
      // a C6 chord in C major 6th diminished is still I
      expect(roman('C E G A', 'C major'), 'Iadd6');
      expect(analyze(placed('C E G A'), c)!.roman!.text, 'Iadd6');
    });
  });
}
