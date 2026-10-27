// striso_core's client against the virtual board's settings: the touch and key lists, writes the
// board takes, clamps or refuses; the hero knobs (StcH) of each engine's first voice, all of them
// parameters of that voice; the settings layout (StcX), the state (StcY) and its change counter
// (Stcy). The replies' formats as the firmware writes them: striso_core's
// test/params_touch_settings_test.dart.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  group('settings on the virtual board', skip: libraryMissing, () {
    test('touch and key lists through the client, writes and errors', () async {
      final (b, c) = await boot();
      final touch = (await c.getParams(Target.touch))!;
      expect(touch.count, touch.params.length);
      for (final p in touch.params) {
        expect(p.value, inInclusiveRange(p.min, p.max), reason: p.name);
      }
      final keys = (await c.getParams(Target.keys))!;
      expect(keys.count, 61);
      expect(keys.params[0].name, firmwareKeyName(0));
      final last = touch.params.length - 1;
      final errs = <({int target, int index})>[];
      final sub = c.qErrors.listen(errs.add);
      c.setParam(Target.touch, 0, 2.5);
      c.setParam(Target.touch, last, touch.params[last].max + 8); // clamped to its max
      c.setParam(Target.keys, 27, 1.25);
      c.setParam(Target.keys, 28, keys.params[28].max * 2); // out of range: Q err
      c.setParam(Target.keys, 61, 1); // no such key: Q err
      await sleep(80);
      final t2 = (await c.getParams(Target.touch))!.params;
      expect(t2[0].value, 2.5);
      expect(t2[last].value, touch.params[last].max);
      final k2 = (await c.getParams(Target.keys))!.params;
      expect(k2[27].value, 1.25);
      expect(k2[28].value, keys.params[28].value);
      expect(errs, [(target: Target.keys, index: 28), (target: Target.keys, index: 61)]);
      await sub.cancel();
    });

    test('StcH follows the voice: each engine\'s hero knobs are parameters of its voice or the effects', () async {
      final (b, c) = await boot();
      final voices = await c.listVoices();
      final fx = {for (final p in (await c.getParams(Target.fx))!.params) p.name};
      final firsts = <String, VoiceEntry>{};
      for (final v in voices) {
        firsts.putIfAbsent(v.engine, () => v);
      }
      expect(firsts.length, greaterThan(3));
      for (final v in firsts.values) {
        expect((await c.selectVoice(v.index))?.ok, isTrue, reason: v.name);
        final h = (await c.getHeroes())!;
        expect(h.voice, v.index, reason: v.name);
        final own = {for (final p in (await c.getParams(Target.voice))!.params) p.name};
        expect(own, containsAll(h.params), reason: v.name);
        expect(fx, containsAll(h.fx), reason: v.name);
      }
    });

    test('X, Y and y: the counter goes up when the state changes, not between idle reads', () async {
      final (b, c) = await boot();
      final layout = (await c.getSettingsLayout())!;
      expect(layout.keys, isNotEmpty);
      final n0 = (await c.getChangeCount())!;
      expect(await c.getChangeCount(), n0);
      final s0 = (await c.getState())!;
      final key = layout.keys.entries.firstWhere((e) => e.value.switchable && e.value.tuningIndex > 0 && e.value.tuningIndex != s0.tuning);
      expect((await c.pressSettingsKey(key.key))!.ok, isTrue);
      final n1 = (await c.getChangeCount())!;
      expect(n1, greaterThan(n0));
      final s1 = (await c.getState())!;
      expect(s1.tuning, key.value.tuningIndex);
      expect(s1.counter, n1);
    });
  });
}
