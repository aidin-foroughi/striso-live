// striso_core's client against the virtual board (the firmware's own code): the version, the voice
// list and the parameter lists while the stream runs, a voice switch, a burst of writes coalesced,
// writes the board clamps or refuses (Q err), replies to back to back commands kept apart, the key
// layout (StcG) against what the stream, the key list and StcN say of the keys, and an engine
// package into a slot with its progress, as the board lists it, and the board's refusals.
// What the board answers is what is expected. The client without a board: striso_core's
// test/client_test.dart.
import 'dart:io';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  group('the client on the virtual board', skip: libraryMissing, () {
    test('the parameters\' words (Stcw): an icon, a label and a hover text for every parameter, in Stcp\'s order', () async {
      final (b, c) = await boot();
      final voices = await c.listVoices();
      final va = voices.firstWhere((x) => x.name.startsWith('va:'));
      expect((await c.selectVoice(va.index))?.ok, isTrue);
      final ps = (await c.getParams(Target.voice))!;
      final w = await c.getWords();
      if (w == null) return markTestSkipped('this firmware has no Stcw');
      expect(w.name, ps.name);
      expect(w.words.length, ps.params.length);
      applyWords(ps.params, w.words);
      for (final p in ps.params) {
        expect(p.icon, isNotEmpty, reason: p.name);
        expect(p.label, isNotEmpty, reason: p.name);
        expect(p.hover, isNotEmpty, reason: p.name);
      }
      expect(ps.params.first.icon, 'level');
      b.dispose();
    });

    test('version, voices, params, voice switch and parameter writes while streaming', () async {
      final (b, c) = await boot();
      var keys = 0, motions = 0;
      final ids = <int>{};
      c.onStream = (src, id, vals, n) {
        if (src == Src.dis && n == 4) {
          keys++;
          ids.add(id);
        }
        if (src == Src.accel && n == 7) motions++;
      };
      final v = (await c.getVersion())!;
      expect(v.line, startsWith(b.firmwareVersion));
      c.startStream();

      final voices = await c.listVoices();
      expect(voices.length, b.state.voices);
      expect(voices.where((x) => x.current).single.index, b.state.voice);
      final p0 = (await c.getParams(Target.voice))!;
      expect(p0.name, voices[b.state.voice].name);
      expect(p0.complete, isTrue);
      expect(p0.params.length, p0.count);
      final f = (await c.getParams(Target.fx))!;
      expect(f.name, 'fx');
      expect(f.complete, isTrue);

      // a voice whose name has a space: the reply keeps it whole
      final spaced = voices.firstWhere((x) => x.name.contains(' '));
      expect(await c.selectVoice(spaced.index), (ok: true, index: spaced.index, name: spaced.name));
      expect(b.state.voice, spaced.index);
      final ps = (await c.getParams(Target.voice))!;
      expect(ps.name, spaced.name);

      // a burst of writes to one parameter is coalesced; the last value wins
      final p = ps.params.firstWhere((x) => x.kind == Kind.continuous && x.max > x.min);
      for (var k = 0; k <= 100; k++) {
        c.setParam(Target.voice, p.index, p.min + (p.max - p.min) * k / 200);
      }
      final fp = f.params.firstWhere((x) => x.kind == Kind.continuous && x.max > x.min);
      final fTarget = conformValue(fp, fp.min + 0.75 * (fp.max - fp.min));
      c.setParam(Target.fx, fp.index, fTarget);
      await sleep(80);
      expect((await c.getParams(Target.voice))!.params[p.index].value, conformValue(p, p.min + (p.max - p.min) * 0.5));
      expect((await c.getParams(Target.fx))!.params[fp.index].value, fTarget);
      expect(c.sentParams, lessThan(10));

      final l = await c.getLoad();
      expect(l != null && l.budget > 0, isTrue);

      // a parameter past the voice's last: the board answers Q err
      final errs = <({int target, int index})>[];
      final sub = c.qErrors.listen(errs.add);
      c.setParam(Target.voice, ps.count, 1);
      await sleep(80);
      expect(errs, [(target: Target.voice, index: ps.count)]);
      await sub.cancel();

      // keys played on the board arrive as stream messages, with the motion sensor's; every id the
      // stream reports is a button of the board's key layout
      final layout = (await c.getKeyLayout())!;
      final played = layout.keys[30].id;
      for (var k = 0; k < 20; k++) {
        b.injectKey(played, pres: 2000 + 50 * k, velo: k == 0 ? 2000 : 0);
        await sleep(20);
      }
      b.injectKey(played, pres: 0);
      await sleep(100);
      expect(keys, greaterThan(5));
      expect(motions, greaterThan(20));
      expect(ids, contains(played));
      for (final id in ids) {
        expect(layout.keyIds, contains(id));
      }
      expect(c.parser.stats.truncated, 0);

      await c.disconnect();
      await until(() => !b.state.streaming); // disconnect stops the stream
    });

    test('touch and key targets: list, write, clamp and errors', () async {
      final (b, c) = await boot();
      final g = (await c.getParams(Target.touch))!;
      expect(g.complete, isTrue);
      final k = (await c.getParams(Target.keys))!;
      expect(k.params.length, 61);
      final layout = (await c.getKeyLayout())!;
      expect(k.params.map((p) => p.name), [for (final key in layout.keys) key.name], reason: 'the key list in key-number order, named as the layout names the keys');
      final errs = <({int target, int index})>[];
      final sub = c.qErrors.listen(errs.add);
      c.setParam(Target.keys, 5, k.params[5].max * 2); // out of range: the board answers Q err
      c.setParam(Target.touch, 0, g.params[0].max * 2); // clamps to its max
      c.setParam(Target.keys, 6, 1.25);
      await sleep(80);
      expect(errs, [(target: Target.keys, index: 5)]);
      expect((await c.getParams(Target.touch))!.params[0].value, g.params[0].max);
      final k2 = (await c.getParams(Target.keys))!.params;
      expect(k2[6].value, toFloat32(1.25));
      expect(k2[5].value, k.params[5].value, reason: 'the refused write changed nothing');
      await sub.cancel();
    });

    test('the key layout (StcG): the keys StcN names and tunes, the same in 12-TET', () async {
      final (b, c) = await boot();
      final layout = (await c.getKeyLayout())!;
      expect(layout.keys.length, 61);
      expect(layout.keyIds.every((id) => id < layout.buttons), isTrue);
      expect(layout.flip, isFalse, reason: 'the factory settings');
      final t = (await c.getTuning())!;
      expect(t.isPlain12, isTrue);
      expect(t.base, layout.startNote);
      // StcN by key number: its names are the layout's, and every key plays its 12-TET pitch
      final named = <int, String>{};
      for (final l in (await c.request(Cmd.tuning(), (l, s) => tuningKeyLine.hasMatch(l) ? Take.more : Take.no, idle: const Duration(milliseconds: 90))).lines) {
        final f = l.trim().split(RegExp(r'\s+'));
        named[int.parse(f[0])] = f[1];
      }
      for (final k in layout.keys) {
        expect(named[k.n], k.name, reason: 'key ${k.n}');
        expect(t.pitchOfButton(layout, k.id), closeTo(layout.startNote + 12 * k.c0 + 7 * k.c1, 1e-4), reason: 'key ${k.n} ${k.name}');
      }
    });

    test('replies to back to back commands are not mixed up', () async {
      final (b, c) = await boot();
      c.startStream();
      final r = await Future.wait([c.listVoices(), c.getParams(Target.voice), c.getLoad(), c.getParams(Target.fx)]);
      expect((r[0] as List).length, b.state.voices);
      expect((r[1] as ParamList).target, Target.voice);
      expect((r[2] as LoadReading).blocks, greaterThanOrEqualTo(0));
      expect((r[3] as ParamList).target, Target.fx);
    });

    // the package: this PC's accordion from the firmware build's test packages (as
    // virtual_board_test.dart's engine module tests find it)
    final accordion = testPackage('accordion');
    test('engine slots: install with progress, listed as the board took it; the board\'s refusals', skip: accordion == null ? 'no accordion.awvapkg (\$STRISO_PACKAGE_DIR or the firmware build)' : null, () async {
      final dir = Directory.systemTemp.createTempSync('sv-slots');
      addTearDown(() => dir.deleteSync(recursive: true));
      final (b, c) = await boot(moduleStore: '${dir.path}${Platform.pathSeparator}modules.bin');
      final slots = (await c.listModuleSlots())!;
      expect(slots, isNotEmpty);
      expect(slots.map((s) => s.state).toSet(), {SlotState.empty});
      final own = (await c.listVoices()).length;
      final pkg = File(accordion!).readAsBytesSync();
      final seen = <int>[];
      final r = await c.installModule(pkg, onProgress: (n, t) => seen.add(n));
      expect(r.ok, isTrue, reason: r.error);
      expect(r.error, isNull, reason: 'the progress crcs match what was sent');
      expect(r.tag, isNotEmpty, reason: 'the board\'s image tag');
      expect(seen.last, pkg.length);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
      final d = r.done!;
      expect(d.slot, slots.first.slot, reason: 'the first free slot');
      final listed = (await c.listModuleSlots())!.firstWhere((s) => s.slot == d.slot);
      expect([listed.state, listed.id, listed.version, listed.abi], [SlotState.ok, d.id, d.version, d.abi]);
      expect(listed.bytes, greaterThan(0));
      expect((await c.listVoices()).length, own, reason: 'a new module loads at the next start');
      // refused: bytes that are no package; a slot past the last
      final junk = await c.installModule([1, 2, 3]);
      expect(junk.ok, isFalse);
      expect(junk.error, isNotEmpty);
      final past = slots.last.slot + 1;
      expect(await c.eraseModuleSlot(past), allOf(isNotNull, contains('$past')));
      expect(await c.eraseModuleSlot(d.slot), isNull);
      expect((await c.listModuleSlots())!.where((s) => s.holdsEngine), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
