// The tuning reply (StcN) as the firmware writes it for its tunings (test/fixtures/tunings.txt),
// their names from its settings layout (test/fixtures/settings_layout.txt), the quarter-tone
// notation of what its keys play; the settings-key command (StcK); a firmware without N or K. The
// client switching the board's tunings: packages/striso_virtual/test/tuning_test.dart.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/silent_transport.dart';

String hx(double v) => floatToHex(v);

final _tunings = readFixture('tunings.txt');

/// The firmware's N reply for its tuning [n] (header + 61 keys).
List<String> reply(int n) => _tunings['tuning $n'];

/// The firmware's settings layout (StcX): it names the tunings.
final layout = parseSettingsLayout(readFixture('settings_layout.txt')['X'])!;

int buttonOf(int c0v, int c1v) => keyIds.firstWhere((id) => c0[id] == c0v && c1[id] == c1v);

void main() {
  group('N reply parser', () {
    test('a full reply: generators, offset, colour, 61 keys', () {
      final lines = reply(1);
      expect(lines.length, 62);
      expect(lines.first, startsWith('tuning 1 '));
      final t = parseTuningReply(lines)!;
      expect(t.index, 1);
      expect(t.fifthCents, closeTo(696.7742, 0.001));
      expect(t.octaveCents, closeTo(1200, 0.001));
      expect(t.offsetCents, closeTo(0, 1e-6));
      expect(t.color, 0x005555);
      expect(t.base, 62);
      expect(t.keyOffsets.length, 61);
      expect(t.keyOffsets.values.every((o) => o == 0), isTrue);
      expect(lines.first, matches(RegExp(r'^tuning 1 [0-9A-F]{8} [0-9A-F]{8} [0-9A-F]{8} 005555 [0-9A-F]{8} 61$')));
      expect(lines[1], matches(RegExp(r'^0 F_1 [0-9A-F]{8} [0-9A-F]{8}$')));
      expect(t.complete, isTrue);
      expect(t.notes.length, 61);
      // D4 (button 25, key number 30: D_3 in the reply) is the anchor: exactly 62
      expect(t.pitchOfButton(25), closeTo(62, 1e-5));
      expect(t.nameIn(layout).name, '31-TET');
      expect(t.hasKeyOffsets, isFalse);
      expect(t.isPlain12, isFalse);
    });

    test('decimal numbers, cents where semitones would be absurd, no colour', () {
      final t = parseTuningReply(['tuning -1 696.8 1200 -32', '30 D_3 62.0', '37 G_3 6703.2'])!;
      expect(t.index, -1);
      expect(t.fifth, closeTo(6.968, 1e-9));
      expect(t.octave, 12);
      expect(t.offsetCents, closeTo(-32, 1e-9));
      expect(t.color, isNull);
      expect(t.base, isNull);
      expect(t.notes[30], 62.0);
      expect(t.notes[37], closeTo(67.032, 1e-9)); // cents
      expect(t.complete, isFalse);
      expect(t.nameIn(layout).name, 'custom: fifth 696.8 ¢');
    });

    test('partial replies: header only, keys only, noise lines, duplicates, bad values', () {
      final headerOnly = parseTuningReply(['tuning 0 ${hx(7)} ${hx(12)} ${hx(0)} 00aa00'])!;
      expect(headerOnly.notes, isEmpty);
      expect(headerOnly.isPlain12, isTrue);
      final keysOnly = parseTuningReply(['3 G_1 ${hx(43.0)}', '4 Ab1 ${hx(44.0)}'])!;
      expect(keysOnly.index, -1);
      expect(keysOnly.notes, {3: 43.0, 4: 44.0});
      final noisy = parseTuningReply([
        'Stcs',
        'tuning 2 ${hx(6.947368)} ${hx(12)} ${hx(0)} 0000aa ${hx(74)} 61',
        'synth blocks 1526 avg 40210 peak 61002 budget 314572 cycles',
        '5 G#1 ${hx(44.5)}',
        '5 G#1 ${hx(44.6)}', // repeated: the last wins
        '99 X_9 ${hx(50)}', // not a key
        '6 A_1 zzzzzzzz', // not a number
        '7 Bb1 ${hx(double.nan)}',
        '8 B_1 ${hx(-5)}',
        '',
      ])!;
      expect(noisy.index, 2);
      expect(noisy.base, 74); // transposed an octave up
      expect(noisy.nameIn(layout).name, '19-TET');
      expect(noisy.notes, {5: closeTo(44.6, 1e-5)});
    });

    test('garbage and silence give null', () {
      expect(parseTuningReply([]), isNull);
      expect(parseTuningReply(['', 'Stcs', 'params 2 touch 5', 'hello world']), isNull);
      expect(parseTuningReply(['tuning x y z w']), isNull);
    });

    test('a board without N: the request times out, the parser returns null', () async {
      final silent = StrisoClient(SilentTransport());
      await silent.connect();
      final sw = Stopwatch()..start();
      expect(await silent.getTuning(), isNull);
      expect(sw.elapsedMilliseconds, lessThan(1500));
      await silent.disconnect();
    });
  });

  group('tuning names', () {
    test('a tuning is named as the board names it (its StcX key), a changed generator is custom', () {
      final expected = ['12-TET', '31-TET', '19-TET', 'Pythagorean', '5-TET', '7-TET', 'Bohlen-Pierce 1', 'Bohlen-Pierce 2', 'Just 7-limit'];
      for (var n = 0; n < 9; n++) {
        final t = parseTuningReply(reply(n))!;
        expect(t.nameIn(layout).name, expected[n], reason: 'tuning $n');
        expect(t.hasKeyOffsets, n == 8);
        if (n == 8) expect(t.keyOffsets[30]! * 100, closeTo(10.3616, 1e-3)); // D's just offset
        // the per-key offsets are also found from the pitches alone (a reply without them)
        final bare = reply(n).map((l) => l.startsWith('tuning') ? l : l.split(' ').take(3).join(' ')).toList();
        expect(parseTuningReply(bare)!.keyOffsets, isEmpty);
        expect(parseTuningReply(bare)!.hasKeyOffsets, n == 8, reason: 'tuning $n from pitches');
      }
      expect(parseTuningReply(reply(1))!.nameIn(layout).short, '31TET');
      final lines = reply(8).map((l) => l.startsWith('tuning 8 ') ? l.replaceFirst('tuning 8 ', 'tuning -1 ') : l).toList();
      expect(parseTuningReply(lines)!.nameIn(layout), (name: 'custom: per-key offsets', short: 'custom'));
      expect(TuningInfo(index: -1, fifth: 7.03, octave: 12, offset: 0).nameIn(layout).name, 'custom: fifth 703.0 ¢');
      expect(TuningInfo(index: -1, fifth: 7, octave: 12.1, offset: 0).nameIn(layout).name, 'custom: fifth 700.0 ¢, octave 1210.0 ¢');
      expect(TuningInfo(index: 1, fifth: 6.967742, octave: 12, offset: 0).nameIn(SettingsLayout.empty).short, 'custom', reason: 'no layout, no name');
    });

    test('the fine tune reads as a reference pitch', () {
      expect(TuningInfo(index: 0, fifth: 7, octave: 12, offset: 0).referenceText, isNull);
      expect(TuningInfo(index: 0, fifth: 7, octave: 12, offset: -0.317667).referenceText, 'A = 432.0 Hz (−32 ¢)');
      expect(TuningInfo(index: 0, fifth: 7, octave: 12, offset: 0.1).referenceText, 'A = 442.5 Hz (+10 ¢)');
      expect(TuningInfo(index: 0, fifth: 7, octave: 12, offset: -0.32).isPlain12, isFalse);
    });
  });

  group('quarter-tone notation', () {
    test('12-TET notes are exact: no fraction, the spelled accidental', () {
      final cs = quarterToneLabel(61, 'C');
      expect(cs.qt, 2);
      expect(cs.nearest, 2);
      expect(cs.frac, 0);
      expect(cs.centsFrom12, 0);
      expect(cs.octave, 4);
      expect(cs.accidentalName, 'sharp');
      final db = quarterToneLabel(61, 'D');
      expect(db.nearest, -2);
      expect(db.accidentalName, 'flat');
      expect(quarterToneLabel(60, 'C').accidentalName, 'natural');
      expect(quarterToneLabel(69, 'A').octave, 4);
      expect(quarterToneLabel(59, 'B').octave, 3);
      expect(quarterToneLabel(60, 'B').octave, 3); // C♯... B♯4? no: B♯ of octave 3 is 60
    });

    test('rounding to quarter tones, the fraction and its edges', () {
      // 60.5 = C half-sharp exactly
      expect(quarterToneLabel(60.5, 'C').nearest, 1);
      expect(quarterToneLabel(60.5, 'C').frac, closeTo(0, 1e-9));
      // 125 cents above C: two strokes and a half (62.5 cents would be a stroke and a quarter)
      final l = quarterToneLabel(61.25, 'C');
      expect(l.qt, closeTo(2.5, 1e-9));
      expect(l.nearest, 3); // half away from zero
      expect(l.fracCents, closeTo(-25, 1e-6));
      expect(quarterToneLabel(60.625, 'C').qt, closeTo(1.25, 1e-9));
      // just under the edge rounds down
      final u = quarterToneLabel(61.249, 'C');
      expect(u.nearest, 2);
      expect(u.fracCents, closeTo(24.9, 0.01));
      // -25 cents: a flat and a half
      final f = quarterToneLabel(61.375, 'D');
      expect(f.qt, closeTo(-1.25, 1e-9));
      expect(f.frac.abs(), closeTo(0.25, 1e-9));
    });

    test('octave wrap: the natural nearest the pitch, B and C across the boundary', () {
      final b = quarterToneLabel(60.2, 'B'); // B sharp-ish, octave 3
      expect(b.octave, 3);
      expect(b.qt, closeTo(2.4, 1e-9));
      final c = quarterToneLabel(59.8, 'C'); // C a little flat, octave 4
      expect(c.octave, 4);
      expect(c.qt, closeTo(-0.4, 1e-9));
      expect(quarterToneLabel(71.9, 'C').octave, 5);
      expect(quarterToneLabel(72.1, 'B').octave, 4);
    });

    test('an accidental past 3½ quarter tones respells to the nearest letter', () {
      final l = quarterToneLabel(62.4, 'C'); // 4.8 quarter tones above C
      expect(l.respelled, isTrue);
      expect(l.letter, 'D');
      expect(l.qt, closeTo(0.8, 1e-9));
      expect(quarterToneLabel(61.7, 'C').respelled, isFalse); // 3.4: kept on C
    });

    test('31-TET and just intonation keys, as the board plays them (D4 = 62 exact)', () {
      final t31 = parseTuningReply(reply(1))!;
      // C♯4: 7 fifths up, 3 octaves down from D4
      final cs = quarterToneLabel(t31.pitchOfButton(buttonOf(-3, 5))!, 'C', nominalMidi: 61);
      expect(cs.qt, closeTo(1.677, 0.001));
      expect(cs.nearest, 2);
      expect(cs.frac, closeTo(-0.323, 0.001));
      expect(cs.centsFrom12, closeTo(-16.1, 0.1));
      // D♭4: 7 fifths down, 4 octaves up
      final db = quarterToneLabel(t31.pitchOfButton(buttonOf(4, -7))!, 'D', nominalMidi: 61);
      expect(db.qt, closeTo(-1.548, 0.001));
      expect(db.nearest, -2);
      expect(db.frac, closeTo(0.452, 0.001));
      expect(db.centsFrom12, closeTo(22.6, 0.1));
      // C4 is 6.45 cents sharp (the system is anchored on D), A4 3.2 cents flat
      expect(quarterToneLabel(t31.pitchOfButton(buttonOf(1, -2))!, 'C').centsFrom12, closeTo(6.45, 0.01));
      expect(quarterToneLabel(t31.pitchOfButton(buttonOf(0, 1))!, 'A').centsFrom12, closeTo(-3.2, 0.05));
      // just 7-limit: E4 a 5/4 above C (-13.7 vs C) and C +6.45: -7.2 cents absolute
      final just = parseTuningReply(reply(8))!;
      final e = quarterToneLabel(just.pitchOfButton(buttonOf(-1, 2))!, 'E');
      expect(e.centsFrom12, closeTo(-7.2, 0.05));
      expect(e.qt, closeTo(-0.145, 0.001));
      // A♯4 at 7/4 above C (968.8 cents): 75.3 cents above A absolute, so a sharp a shade short
      final asharp = quarterToneLabel(just.pitchOfButton(buttonOf(-4, 8))!, 'A', nominalMidi: 70);
      expect(asharp.qt, closeTo(1.506, 0.001));
      expect(asharp.centsFrom12, closeTo(-24.7, 0.1));
      expect(asharp.nearest, 2);
      expect(asharp.frac, closeTo(-0.494, 0.001));
      // 7-TET: C♯ is C (both 28.6 cents above 12-TET C, a half-sharp), D♭ is D
      final t7 = parseTuningReply(reply(5))!;
      expect(t7.pitchOfButton(buttonOf(-3, 5)), closeTo(t7.pitchOfButton(buttonOf(1, -2))!, 1e-5));
      expect(quarterToneLabel(t7.pitchOfButton(buttonOf(-3, 5))!, 'C').nearest, 1);
      expect(quarterToneLabel(t7.pitchOfButton(buttonOf(4, -7))!, 'D').nearest, 0);
      // 12-TET with the fine dial at -31.25 cents: every key reads -0.625 qt absolute, exact once the
      // offset is taken out
      final low = parseTuningReply(_tunings['tuning 0 fine -31.25'])!;
      expect(low.offsetCents, closeTo(-31.25, 1e-3));
      final a = low.pitchOfButton(buttonOf(0, 1))!;
      expect(quarterToneLabel(a, 'A').qt, closeTo(-0.625, 1e-3));
      expect(quarterToneLabel(a - low.offset, 'A').qt, closeTo(0, 1e-3));
    });

    test('names and cents text', () {
      expect(quarterToneLabel(60.5, 'C').name, 'C\u{1D132}4');
      expect(quarterToneLabel(60.0, 'C').name, 'C4');
      expect(quarterToneLabel(61.5, 'D').name, 'D\u{1D133}4');
      expect(QtLabel.accidentalNameOf(-3), 'sesquiflat');
      expect(QtLabel.accidentalNameOf(3), 'sesquisharp');
      expect(centsText(16.13), '+16');
      expect(centsText(-22.58), '−23');
      expect(centsText(0.3), '0');
      expect(centsText(-7.23, decimals: 1), '−7.2');
    });
  });

  group('settings keys over USB (StcK)', () {
    test('the command and its replies', () {
      expect(settingsKeyCommand(36), [0x53, 0x74, 0x63, 0x4b, 36]);
      expect(parseSettingsKeyReply('K ok 36'), (ok: true, id: 36));
      expect(parseSettingsKeyReply('K err 67'), (ok: false, id: 67));
      expect(parseSettingsKeyReply('Q err 0 1'), isNull);
    });

    test('a board without K answers nothing within the timeout', () async {
      final c = StrisoClient(SilentTransport());
      await c.connect();
      final sw = Stopwatch()..start();
      expect(await c.pressSettingsKey(36), isNull);
      expect(sw.elapsedMilliseconds, inInclusiveRange(250, 1200));
      await c.disconnect();
    });

    test('the whitelist is the one the board lists (StcX k flags): switch keys yes, dials and reset no', () {
      final l = layout;
      final sw = l.keys.entries.where((e) => e.value.switchable).map((e) => e.key).toSet();
      expect(sw, containsAll([0, 2, 4, 34, 36, 35, 63, ...l.voiceKeys.map((v) => v.$1)]));
      expect(sw, isNot(contains(67)));
      expect(sw, isNot(contains(65)));
      for (final id in [17, 19, 21, 6, 8, 51, 53, 56, 58, 11]) {
        expect(l[id]!.switchable, isFalse, reason: 'key $id is a dial or flip');
      }
    });
  });
}
