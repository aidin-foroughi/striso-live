// Ports of tools/app/test/params.test.mjs, touch.test.mjs and settings.test.mjs.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/firmware.dart';

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

List<Param> P() => [
  Param(index: 0, name: 'gain', group: 'level', min: 0, max: 4, kind: 0, value: 1),
  Param(index: 1, name: 'steps', group: 'osc', min: 0, max: 7, kind: 1, value: 2),
  Param(index: 2, name: 'sync', group: 'osc', min: 0, max: 1, kind: 2, value: 0),
];
Snapshot corner(Map<String, double> v) => Snapshot('va:pad', {0: v, 1: {}});

/// The firmware source ($STRISO_FW_DIR or ../striso-control-firmware, see support/firmware.dart).
File? firmwareSource() {
  final d = firmwareDir();
  return d == null ? null : File('${d.path}/synth_control.cpp');
}

void main() {
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
    test('key numbers: 61 distinct buttons, names like the firmware', () {
      expect(buttonNumberMap.length, 61);
      expect([...buttonNumberMap]..sort(), [...keyIds]..sort());
      expect(keyNumberOf[56], 0);
      expect(firmwareKeyName(0), 'F_1');
      expect(firmwareKeyName(1), 'Gb1');
      expect(firmwareKeyName(2), 'F#1');
      expect(firmwareKeyName(10), 'C_2');
      expect(firmwareKeyName(60), 'B_4');
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
      final live = LiveState();
      void f(int id, int p, double t) => live.apply(Src.dis, id, Int32List.fromList([p, 0, 0, 0]), 4, t);
      final presses = <int>[];
      live.pressListeners.add((id, _) => presses.add(id));
      f(25, 2000, 1);
      f(25, 4000, 2);
      f(25, 3000, 3);
      f(25, 0, 4);
      expect(presses, [25]);
      expect(live.lastPeak[25], closeTo(4000 / 8191, 1e-6));
      expect(live.lastPeakT[25], 4);
      f(30, 6000, 10);
      f(30, 9000 - 16384, 11);
      expect(live.down[30], 1);
      expect(live.pres[30], closeTo(9000 / 8191, 1e-6));
      f(30, 0, 12);
      expect(live.lastPeak[30], greaterThan(1.09));
    });

    test('touch and key lists through the client, writes and errors, the mock board responds', () async {
      final t = MockTransport(board: MockBoard(autoplay: false, idleFrames: 0));
      final c = StrisoClient(t);
      await c.connect();
      final touch = (await c.getParams(2))!;
      expect(touch.params.map((p) => p.name), ['pressure', 'velocity', 'tilt', 'bend', 'threshold']);
      expect(touch.params.map((p) => [p.min, p.max, p.value]), [
        [toFloat32(0.1), 4, 1],
        [toFloat32(0.1), 4, 1],
        [-4, 4, 1],
        [0, 8, 0.5],
        [0, 0.5, 0],
      ]);
      final keys = (await c.getParams(3))!;
      expect(keys.count, 61);
      expect(keys.params[0].name, 'F_1');
      expect(keys.params.every((p) => p.value == 1 && p.max == 10), isTrue);
      final errs = <({int target, int index})>[];
      c.qErrors.listen(errs.add);
      c.setParam(2, 0, 2.5);
      c.setParam(2, 4, 9);
      c.setParam(3, 27, 1.25);
      c.setParam(3, 28, 20);
      c.setParam(3, 61, 1);
      await sleep(80);
      expect(t.board.touch[0], 2.5);
      expect(t.board.touch[4], 0.5);
      expect(t.board.keyFactors[27], 1.25);
      expect(errs, [(target: 3, index: 28), (target: 3, index: 61)]);
      final live = LiveState();
      final clock = Stopwatch()..start();
      c.onStream = (src, id, v, n) => live.apply(src, id, v, n, clock.elapsedMilliseconds.toDouble());
      c.startStream();
      final id = buttonNumberMap[27];
      Future<double> press() async {
        t.board.press(id, pres: 0.3, strike: 0);
        await sleep(60);
        t.board.release(id);
        await sleep(60);
        return live.lastPeak[id];
      }

      final p1 = await press();
      c.setParam(3, 27, 2.5);
      await sleep(40);
      final p2 = await press();
      expect(p2 / p1, closeTo(2.5 / 1.25, 0.01));
      await c.disconnect();
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

  group('settings', () {
    test('every settings key is a key on the board', () {
      for (final id in settingsKeys.keys) {
        expect(keyIds, contains(id), reason: 'key $id');
      }
    });

    final fw = firmwareSource();
    test('the table matches config_but() and config_voice() in the firmware', () {
      final src = fw!.readAsStringSync();
      final start = src.indexOf('#else // !OLD_CONFIG_LAYOUT');
      final body = src.substring(start, src.indexOf('#endif // !OLD_CONFIG_LAYOUT', start));
      final fn = body.substring(body.indexOf('float config_but('));
      final live = fn.split('\n').where((l) => !RegExp(r'^\s*//').hasMatch(l)).join('\n');
      final cases = {for (final m in RegExp(r'case \((\d+)\)').allMatches(live)) int.parse(m[1]!)}.toList()..sort();
      expect(cases, settingsKeys.keys.toList()..sort());
      final voices = RegExp(r'case \((\d+)\): return config_voice\("(\w+)", (\d+), (\d+), (\d+)').allMatches(live).toList();
      expect(voices.length, voiceKeys.length);
      for (final m in voices) {
        final v = voiceKeys[int.parse(m[1]!)]!;
        expect([v.$1, ...v.$2], [m[2], int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!)], reason: 'voice key ${m[1]}');
      }
      final tunings = RegExp(r'case \((\d+)\): // (?:set 12tet tuning|load tuning (\d))').allMatches(live);
      expect(tunings.length, 9);
      for (final m in tunings) {
        final n = m[2] != null ? int.parse(m[2]!) : 0;
        expect(settingsKeys[int.parse(m[1]!)]!.title, startsWith('Tuning $n: '), reason: 'tuning key ${m[1]}');
      }
      final presets = RegExp(r'case \((\d+)\):\s*\n\s*if \(type == 0\) \{\s*\n\s*load_preset\((\d)\)').allMatches(live).toList();
      expect(presets.length, 8);
      for (final m in presets) {
        expect(settingsKeys[int.parse(m[1]!)]!.short, 'P${m[2]}', reason: 'preset key ${m[1]}');
      }
    }, skip: fw == null ? firmwareMissing : false);

    test('voice keys: select with the remembered preset, then step through the presets', () {
      const voices = [
        VoiceEntry(index: 0, name: 'strisy', engine: 'strisy'),
        VoiceEntry(index: 1, name: 'va:classic', engine: 'va'),
        VoiceEntry(index: 2, name: 'va:pad', engine: 'va'),
        VoiceEntry(index: 3, name: 'va:lead', engine: 'va'),
        VoiceEntry(index: 4, name: 'modal:bell', engine: 'modal'),
      ];
      expect(voiceKeyAction(voices, 0, 'va'), (index: 1, name: 'va:classic', presetIndex: 0, count: 3));
      expect(voiceKeyAction(voices, 0, 'va', {'va': 2})!.name, 'va:lead');
      expect(voiceKeyAction(voices, 1, 'va')!.name, 'va:pad');
      expect(voiceKeyAction(voices, 3, 'va')!.name, 'va:classic');
      expect(voiceKeyAction(voices, 1, 'va', {}, -1)!.name, 'va:lead');
      expect(voiceKeyAction(voices, 4, 'strisy')!.name, 'strisy');
      expect(voiceKeyAction(voices, 4, 'wind'), isNull);
      expect(ledColor([64, 20, 0]), 0xff5000);
    });
  });
}
