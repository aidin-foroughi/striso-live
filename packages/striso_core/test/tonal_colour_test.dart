// The mapping behind the board's colouring: scale degree per spelled note, tonal function per
// degree and scale, the role of each pitch class in a recognised chord.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

const T = TonalFunction.tonic, S = TonalFunction.subdominant, D = TonalFunction.dominant;

/// Functions of a key's scale notes in scale order, as 'T S D' letters.
String functions(int pc, String scale) {
  final k = makeKey(pc, scale)!;
  final f = scales[scale]!.fifths!;
  return [for (final x in f) tonalFunction(k, k.tonic + x)!.name[0].toUpperCase()].join(' ');
}

void main() {
  test('scale degrees by letter step: accidentals do not change the number', () {
    final c = makeKey(0, 'major')!;
    expect(scaleDegree(c, parseNote('E').tpc), (deg: 3, acc: 0));
    expect(scaleDegree(c, parseNote('Eb').tpc), (deg: 3, acc: -1));
    expect(scaleDegree(c, parseNote('F#').tpc), (deg: 4, acc: 1));
    expect(scaleDegree(c, parseNote('Bb').tpc), (deg: 7, acc: -1));
    final a = makeKey(9, 'minor')!;
    expect(scaleDegree(a, parseNote('C').tpc), (deg: 3, acc: -1)); // against the major grid, like the degree labels
    expect(scaleDegree(a, parseNote('G#').tpc), (deg: 7, acc: 0)); // the major grid's seventh
    expect(scaleDegree(a, parseNote('G').tpc), (deg: 7, acc: -1)); // the subtonic
  });

  test('functions: 1 3 6 tonic, 2 4 subdominant, 5 7 dominant; a lowered seventh is subdominant', () {
    expect(functions(0, 'major'), 'T S T S D T D');
    expect(functions(9, 'minor'), 'T S T S D T S'); // natural minor: the subtonic G is subdominant
    expect(functions(9, 'harmonic'), 'T S T S D T D'); // G♯ leads: dominant
    expect(functions(9, 'melodic'), 'T S T S D T D');
    expect(functions(7, 'mixolydian'), 'T S T S D T S'); // ♭7
    expect(functions(2, 'dorian'), 'T S T S D T S');
    expect(functions(4, 'phrygian'), 'T S T S D T S'); // ♭2 is still subdominant (Neapolitan side)
    expect(functions(5, 'lydian'), 'T S T S D T D'); // ♯4 stays with 4
    expect(functions(0, 'majpent'), 'T S T D T'); // 1 2 3 5 6
    expect(functions(9, 'minpent'), 'T T S D S'); // 1 ♭3 4 5 ♭7
    // Barry Harris major 6th diminished: 1 2 3 4 5 ♭6 6 7 (both sixths tonic)
    expect(functions(0, 'bh6dim'), 'T S T S D T T D');
    // dominant bebop: ♭7 subdominant, ♮7 dominant
    expect(functions(7, 'bebopdom'), 'T S T S D T S D');
  });

  test('the degree function alone, and notes outside the scale have none', () {
    expect(functionOfDegree(7, -1), S);
    expect(functionOfDegree(7, 0), D);
    expect(functionOfDegree(7, 1), D);
    expect(functionOfDegree(6, -1), T);
    expect(functionOfDegree(2, -1), S);
    expect(functionOfDegree(5, -1), D);
    final c = makeKey(0, 'major')!;
    expect(tonalFunction(c, parseNote('F#').tpc), isNull);
    expect(tonalFunction(c, parseNote('Bb').tpc), isNull);
    expect(tonalFunction(null, 0), isNull);
  });

  group('chord roles', () {
    Map<String, ChordRole?> roles(String held, String ask, [MusicKey? key]) {
      final h = analyze(notes(held), key)!;
      return {for (final n in notes(ask)) tpcName(n.tpc): chordRole(h, pcOf(n.tpc))};
    }

    test('triads and sevenths', () {
      expect(roles('C4 E4 G4', 'C E G F#'), {'C': ChordRole.root, 'E': ChordRole.third, 'G': ChordRole.fifth, 'F♯': null});
      expect(roles('G3 B3 D4 F4', 'G B D F'), {'G': ChordRole.root, 'B': ChordRole.third, 'D': ChordRole.fifth, 'F': ChordRole.seventh});
      expect(roles('B3 D4 F4 A4', 'B D F A'), {'B': ChordRole.root, 'D': ChordRole.third, 'F': ChordRole.fifth, 'A': ChordRole.seventh});
      expect(roles('B3 D4 F4 Ab4', 'Ab'), {'A♭': ChordRole.seventh}); // diminished seventh
      expect(roles('C4 E4 G#4', 'G#'), {'G♯': ChordRole.fifth}); // augmented fifth
      // inversions keep the roles
      expect(roles('E3 G3 C4', 'C E G'), {'C': ChordRole.root, 'E': ChordRole.third, 'G': ChordRole.fifth});
      // the enharmonic pitch class counts too (D# key over an Eb chord tone)
      expect(roles('C4 Eb4 G4', 'D#'), {'D♯': ChordRole.third});
    });

    test('sus, added sixth and extensions', () {
      expect(roles('C4 F4 G4', 'F'), {'F': ChordRole.third}); // sus4: the 4 stands in for the third
      expect(roles('C4 D4 G4', 'D'), {'D': ChordRole.third});
      expect(roles('C4 E4 G4 A4', 'A'), {'A': ChordRole.extension}); // C6
      expect(roles('C4 E4 G4 Bb4 D5', 'D'), {'D': ChordRole.extension}); // C9
      expect(roles('C4 E4 G4 Bb4 F#5', 'F#'), {'F♯': ChordRole.extension}); // 7♯11
      expect(roles('C4 E4 Gb4 Bb4', 'Gb'), {'G♭': ChordRole.fifth}); // 7♭5
      expect(roles('C4 E4 G4 Bb4 Db5', 'Db'), {'D♭': ChordRole.extension}); // 7♭9
    });

    test('not a chord: no roles', () {
      final one = analyze(notes('C4'))!;
      expect(chordRole(one, 0), isNull);
      final two = analyze(notes('C4 G4'))!;
      expect(chordRole(two, 0), isNull);
    });
  });
}
