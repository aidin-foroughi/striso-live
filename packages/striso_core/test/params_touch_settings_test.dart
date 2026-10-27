// Parameters (morph, mutate, undo, presets to JSON and C), the key equalizer math, and what the
// board reports of its settings: StcX as the firmware writes it (test/fixtures/settings_layout.txt),
// StcY, Stcy and StcH. The client against the board's lists, settings and hero knobs:
// packages/striso_virtual/test/settings_test.dart.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/firmware.dart';
import 'support/fixtures.dart';

/// The board's keys (StcG, as the firmware reports them).
final keyLayout = fixtureKeyLayout();

List<Param> P() => [
  Param(index: 0, name: 'gain', group: 'level', min: 0, max: 4, kind: 0, value: 1),
  Param(index: 1, name: 'steps', group: 'osc', min: 0, max: 7, kind: 1, value: 2),
  Param(index: 2, name: 'sync', group: 'osc', min: 0, max: 1, kind: 2, value: 0),
];
Snapshot corner(Map<String, double> v) => Snapshot('va:pad', {0: v, 1: {}});

/// The firmware source ($STRISO_FW_DIR or ../striso-control-firmware, see support/firmware.dart).
File? firmwareSource() => firmwareDir() == null ? null : firmwareFile('synth_control.cpp');

void main() {
  final stcx = readFixture('settings_layout.txt')['X'];

  group('params', () {
    test('corner weights: exact at corners, bilinear inside, sum to one', () {
      const all = [true, true, true, true];
      expect(cornerWeights(0, 0, all)[0], greaterThan(0.999));
      for (final x in cornerWeights(0.5, 0.5, all)) {
        expect(x, closeTo(0.25, 1e-3));
      }
      final two = cornerWeights(0.25, 0.9, [true, true, false, false]);
      expect(two[0], closeTo(0.75, 0.01));
      expect(two[1], closeTo(0.25, 0.01));
      final diag = cornerWeights(1, 0, [true, false, false, true]);
      expect(diag[0], closeTo(0.5, 1e-6));
      expect(diag[3], closeTo(0.5, 1e-6));
      final r = math.Random(5);
      for (var k = 0; k < 200; k++) {
        final ws = cornerWeights(r.nextDouble(), r.nextDouble(), [true, r.nextBool(), true, r.nextBool()]);
        expect(ws.reduce((a, b) => a + b), closeTo(1, 1e-9));
      }
    });

    test('morph interpolates continuous values and snaps integer and on/off ones', () {
      final params = P();
      final corners = <Snapshot?>[
        corner({'gain': 0, 'steps': 0, 'sync': 0}),
        corner({'gain': 4, 'steps': 7, 'sync': 1}),
        null,
        null,
      ];
      final out = morphValues(params, corners, [0.4, 0.6, 0, 0], 0);
      final by = {for (final (p, v) in out) p.name: v};
      expect(by['gain'], toFloat32(2.4));
      expect(by['steps'], 4);
      expect(by['sync'], 1);
      corners[1] = corner({'gain': 4});
      expect(morphValues(params, corners, [0.4, 0.6, 0, 0], 0).map((o) => o.$1.name), ['gain']);
    });

    test('mutate stays in range and skips locked parameters', () {
      final r = math.Random(1);
      for (var k = 0; k < 200; k++) {
        for (final (p, v) in mutateValues(P(), 0.5, r, locked: {'steps'})) {
          expect(v >= p.min && v <= p.max, isTrue);
          expect(p.name, isNot('steps'));
        }
      }
    });

    test('history coalesces a gesture and undoes/redoes it', () {
      final h = History();
      h.begin('Change gain', 'k');
      h.record(0, 'gain', 1, 1.5);
      h.record(0, 'gain', 1.5, 2);
      h.begin('Change gain', 'k');
      h.record(0, 'gain', 2, 2.5);
      h.commit();
      expect(h.canUndo, isTrue);
      expect(h.undo()!.changes, [(0, 'gain', 1.0)]);
      expect(h.undo(), isNull, reason: 'one entry');
      expect(h.redo()!.changes, [(0, 'gain', 2.5)]);
      h.begin('noop');
      h.record(0, 'gain', 3, 3);
      h.commit();
      expect(h.undo()!.label, 'Change gain', reason: 'no entry for a change that changed nothing');
    });

    test('presets round trip through JSON and export to C', () {
      final state = {
        0: P(),
        1: [Param(index: 0, name: 'rv_mix', group: 'reverb', min: 0, max: 1, kind: 0, value: toFloat32(0.22))],
      };
      final pr = makePreset('Velvet pad #2', 'va:pad', state);
      final back = parsePresetFile(collectionJson([pr]));
      expect(back.errors, isEmpty);
      expect(back.presets[0].params.map((p) => p.toJson()), pr.params.map((p) => p.toJson()));
      expect(parsePresetFile('{"name":"x"}').errors.length, 1);
      expect(parsePresetFile('nope').presets, isEmpty);
      final c = presetToC(pr);
      expect(c, contains('static const float preset_velvet_pad_2_va[3] = {'));
      expect(c, matches(RegExp(r'\t1\.0f, +//  0 gain')));
      expect(c, matches(RegExp(r'\t0\.22f, +//  0 rv_mix')));
      expect(cFloat(toFloat32(0.1)), '0.1f');
      expect(cFloat(46), '46.0f');
      expect(cFloat(1e-7), '1e-7f');
      expect(cIdent('9 lives!'), 'p_9_lives');
      expect(formatValue(0, 80, 0, 46), '46.0');
      expect(formatValue(-1, 1, 0, -0.0001), '0.00');
    });
  });

  group('touch', () {
    test('key numbers: the per-key list is in the key layout\'s key-number order, named as it names them', () {
      expect(keyLayout.keys.length, 61);
      expect({for (final k in keyLayout.keys) k.id}, {...keyLayout.keyIds});
      expect(keyLayout.keyNumberOf(keyLayout.keys[27].id), 27);
      expect(parseParamLine('27 ${keyLayout.keys[27].name} keys 3dcccccd 41200000 3f800000 0')!.name, keyLayout.keys[27].name);
      expect(parseParamsHeader('params 3 keys 61'), (target: 3, name: 'keys', count: 61));
      expect(parseParamsHeader('params 2 touch 5'), (target: 2, name: 'touch', count: 5));
      expect(parseParamLine('27 F#2 keys 3dcccccd 41200000 3f800000 0')!.name, 'F#2');
    });

    test('suggest: even out measured keys toward their median, clamp, leave the rest', () {
      expect(median([3, 1, 2]), 2);
      expect(median([4, 1, 3, 2]), 2.5);
      const measured = [
        Measured(n: 0, peak: 0.40, factor: 1),
        Measured(n: 1, peak: 0.50, factor: 1),
        Measured(n: 2, peak: 0.25, factor: 1.2),
        Measured(n: 3, peak: 0.80, factor: 1),
        Measured(n: 4, peak: 0.10, factor: 0.9),
        Measured(n: 5, peak: 0.01, factor: 1),
        Measured(n: 6, peak: 1.8, factor: 1),
      ];
      final r = suggestFactors(measured);
      expect(r.used, 5);
      expect(r.skipped.map((m) => m.n), [5, 6]);
      expect(r.median, 0.4);
      final by = {for (final c in r.changes) c.key.n: c};
      expect(by[0], isNull, reason: 'the median key does not change');
      expect(by[1]!.to, 0.8);
      expect(by[2]!.to, 1.6);
      expect(by[2]!.clamped, isTrue);
      expect(by[3]!.to, 0.6);
      expect(by[4]!.to, 1.6);
      expect(r.changes.every((c) => c.to >= 0.6 && c.to <= 1.6), isTrue);
      expect(r.changes.every((c) => [0, 1, 2, 3, 4].contains(c.key.n)), isTrue);
      expect(suggestFactors(measured.sublist(0, 2)).median, isNull);
      expect(
        suggestFactors(const [
          Measured(n: 0, peak: 0.4, factor: 1),
          Measured(n: 1, peak: 0.401, factor: 1),
          Measured(n: 2, peak: 0.399, factor: 1),
        ]).changes,
        isEmpty,
      );
    });

    test('peaks of each press, and pressure of 1.0 and more unwrapped', () {
      final live = LiveState(keyLayout);
      final a = keyLayout.keyIds[25], b = keyLayout.keyIds[30];
      void f(int id, int p, double t) => live.apply(Src.dis, id, Int32List.fromList([p, 0, 0, 0]), 4, t);
      final presses = <int>[];
      live.pressListeners.add((id, _) => presses.add(id));
      f(a, 2000, 1);
      f(a, 4000, 2);
      f(a, 3000, 3);
      f(a, 0, 4);
      expect(presses, [a]);
      expect(live.lastPeak[a], closeTo(4000 / 8191, 1e-6));
      expect(live.lastPeakT[a], 4);
      f(b, 6000, 10);
      f(b, 9000 - 16384, 11);
      expect(live.down[b], 1);
      expect(live.pres[b], closeTo(9000 / 8191, 1e-6));
      f(b, 0, 12);
      expect(live.lastPeak[b], greaterThan(1.09));
    });

    test('pressure trace keeps the last two seconds in order', () {
      final tr = PressureTrace(window: 2000, size: 8);
      for (var t = 0; t <= 3000; t += 250) {
        tr.push(t.toDouble(), t / 1000);
      }
      expect(tr.points(3000).map((p) => p.$1), [1250, 1500, 1750, 2000, 2250, 2500, 2750, 3000]);
      expect(tr.max(3000), 3);
      expect(tr.points(4900).map((p) => p.$1), [3000]);
      tr.reset();
      expect(tr.points(3000), isEmpty);
    });
  });

  group('settings layout (StcX) and state (StcY, Stcy): what the board reports', () {
    test('the StcX reply parses: kinds, groups, engines, led colours, what K takes', () {
      final l = parseSettingsLayout(stcx)!;
      expect(stcx.first, 'X keys 43');
      expect(l.keys.length, 43);
      for (final id in l.keys.keys) {
        expect(keyLayout.keyIds, contains(id), reason: 'key $id is a key on the board');
      }
      expect(l[0]!.group, SettingsGroup.midi);
      expect(l[0]!.switchable, isTrue);
      expect(l[6]!.kind, 'dial');
      expect(l[6]!.switchable, isFalse);
      expect(l[24]!.engine, 'bowed');
      expect(l[24]!.led, [0x40, 0, 0]);
      expect(l[36]!.title, startsWith('Tuning 1: '));
      expect(l[67]!.danger, isTrue);
      expect(l[67]!.switchable, isFalse);
      expect(l.voiceKeyOf('trumpet'), 15);
      expect(l.voiceKeys.map((v) => v.$2), containsAll(['strisy', 'va', 'modal', 'bowed', 'wind', 'ep', 'brass', 'trumpet']));
      expect(ledColor(l[20]!.led!), 0xff5000);
    });

    test('a reply cut short is no layout (the firmware must answer all of it)', () {
      expect(parseSettingsLayout(stcx.sublist(0, 5)), isNull);
      expect(parseSettingsLayout(const []), isNull);
    });

    test('StcY and Stcy lines', () {
      final b = parseBoardState(
        'Y 17 voice=1 midi=midimono midikey=4 ch=2 voices=10 bend=48 tuning=2 fine=-31.77 transpose=1.161 pres=1.000 velo=1.000 tilt=1.000 '
        'bendsens=0.500 thres=0.000 vol=90 sustain=0.188 rate=1 alt=1 porta=0 flip=0 led=00AA00 updown=0120',
      )!;
      expect(b.counter, 17);
      expect(b.voice, 1);
      expect(b.midi, 'midimono');
      expect(b.midiKey, 4);
      expect(b.tuning, 2);
      expect(b.fineCents, closeTo(-31.77, 1e-9));
      expect(b.transpose, closeTo(1.161, 1e-9));
      expect(b.settingsHeld, isTrue);
      expect(b.led, 0x00AA00);
      expect(b.updown, [0, 1, 2, 0]);
      expect(parseChangeCount('y 42'), 42);
      expect(parseChangeCount('Y 42 voice=1'), isNull);
      expect(parseBoardState('y 4'), isNull);
    });

    test('StcH: the hero knobs as the firmware replies', () {
      final va = parseHeroes('H 1 cut_base res cut_env drive saw2_detune sub release vibrato | rvmix dlmix')!;
      expect(va.voice, 1);
      expect(va.params, ['cut_base', 'res', 'cut_env', 'drive', 'saw2_detune', 'sub', 'release', 'vibrato']);
      expect(va.fx, ['rvmix', 'dlmix']);
      expect(parseHeroes('H 2 cut_base cut_env release saw2_detune drift res sub vibrato | rvmix dlmix')!.params[4], 'drift');
      final strisy = parseHeroes('H 0 | rvmix dlmix\r')!;
      expect(strisy.params, isEmpty);
      expect(strisy.fx, ['rvmix', 'dlmix']);
      expect(parseHeroes('H 0 |')!.fx, isEmpty);
      expect(parseHeroes('H 1 cut_base res'), isNull, reason: 'no bar: not a reply');
      expect(parseHeroes('Y 1 voice=1'), isNull);
    });
  });
}
