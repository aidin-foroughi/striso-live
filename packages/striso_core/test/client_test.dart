// Ports of tools/app/test/client.test.mjs, stream.test.mjs and live.test.mjs: the client against
// the mock board and a scripted board, end to end through the byte stream; the live state.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
List<int> ascii(String s) => s.codeUnits;

const load = 'synth blocks 1526 avg 40210 peak 61002 budget 314572 cycles\r\n';
Uint8List motion(int k) => encodeMessage(Src.accel, 8, [12 + (k % 5), -30, 1021, 1024, 40 - k % 80, 3, -2]);
Uint8List key(int id, int p) => encodeMessage(Src.dis, id, [p, 120, -400, 900]);

// one second of board output: 62 motion frames, key frames for a held D4, an L reply that the
// stream splits at several points
List<int> boardSecond(bool withKeys, [bool splitText = true]) {
  final out = <int>[];
  final text = ascii(load);
  var ti = 0;
  for (var k = 0; k < 62; k++) {
    out.addAll(motion(k));
    if (withKeys) {
      for (var j = 0; j < 11; j++) {
        out.addAll(key(25, 2000 + 10 * j));
      }
    }
    if (k >= 20 && ti < text.length) {
      final n = splitText ? 7 : text.length;
      out.addAll(text.sublist(ti, math.min(text.length, ti + n)));
      ti += n;
    }
  }
  return out;
}

List<Uint8List> packets(List<int> bytes) => [
  for (var k = 0; k < bytes.length; k += 64) Uint8List.fromList(bytes.sublist(k, math.min(bytes.length, k + 64))),
];

/// Answers the connect sequence like the firmware does, streams after 'S'.
class ScriptedBoard implements Transport {
  final bool ignoreFirstS;
  int sCount = 0, k = 0;
  bool streaming = false;
  Timer? _timer;
  final _data = StreamController<Uint8List>.broadcast(sync: true);
  final _lost = Completer<UsbError>();
  ScriptedBoard({this.ignoreFirstS = false});

  @override
  String get label => 'scripted';
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => _lost.future;

  @override
  Future<void> open() async {
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!streaming) return;
      final bytes = <int>[];
      for (var j = 0; j < 2; j++) {
        bytes
          ..addAll(motion(k++))
          ..addAll(key(25, 3000));
      }
      packets(bytes).forEach(_data.add);
    });
  }

  @override
  Future<void> write(Uint8List b) async {
    final cmd = String.fromCharCode(b[3]);
    void reply(String s) => Timer(const Duration(milliseconds: 2), () => packets(ascii(s)).forEach(_data.add));
    switch (cmd) {
      case 'V':
        streaming = false;
        reply('striso_control_strisoboard_v2.2.4 X Y\r\n');
      case 'v':
        reply('* 0 va:classic\r\n  1 va:pad\r\n');
      case 'p':
        reply('params 0 va:classic 1\r\n0 gain level 3f000000 40a00000 40133333 0\r\n');
      case 'f':
        reply('params 1 fx 0\r\n');
      case 'L':
        reply(load);
      case 'S':
        sCount++;
        if (!(ignoreFirstS && sCount == 1)) streaming = true;
    }
  }

  @override
  Future<void> close() async => _timer?.cancel();
}

Future<(StrisoClient, LiveState)> connectLikeTheApp(Transport board) async {
  final c = StrisoClient(board);
  final live = LiveState();
  final clock = Stopwatch()..start();
  c.onStream = (src, id, v, n) => live.apply(src, id, v, n, clock.elapsedMilliseconds.toDouble() + 1);
  await c.connect();
  await c.getVersion();
  await c.listVoices();
  await c.getParams(0);
  await c.getParams(1);
  c.startStream();
  return (c, live);
}

void frame(LiveState live, int id, int pres, int vpres, int x, int y, double t) =>
    live.apply(Src.dis, id, Int32List.fromList([pres, vpres, x, y]), 4, t);

void main() {
  group('mock board', () {
    test('version, voices, params, voice switch and parameter writes while streaming', () async {
      final t = MockTransport();
      final dev = t.board;
      final c = StrisoClient(t);
      await c.connect();
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
      expect(v.fw, contains('_v2.2.4'));
      c.startStream();

      final voices = await c.listVoices();
      expect(voices.length, dev.voiceCount);
      expect(voices.length, 65); // with the 9 trumpet presets
      expect(voices.where((x) => x.engine == 'trumpet').map((x) => x.name), contains('trumpet:cup mute'));
      expect(voices.any((x) => x.name == 'modal:wine glass'), isTrue);
      expect(voices.where((x) => x.current).length, 1);

      final p0 = (await c.getParams(0))!;
      expect(p0.name, 'va:classic');
      expect(p0.params.length, 55);
      expect(p0.complete, isTrue);
      expect(p0.params.firstWhere((p) => p.name == 'gain').value, toFloat32(2.3));
      expect((await c.getParams(1))!.name, 'fx');

      final wine = voices.firstWhere((x) => x.name == 'modal:wine glass');
      final sel = await c.selectVoice(wine.index);
      expect(sel, (ok: true, index: wine.index, name: 'modal:wine glass'));
      expect((await c.getParams(0))!.name, 'modal:wine glass');

      // a burst of writes to one parameter is coalesced; the last value wins
      for (var k = 0; k <= 100; k++) {
        c.setParam(0, 8, 0.1 + k * 0.02);
      }
      c.setParam(1, 2, 0.75);
      await sleep(80);
      expect(dev.values[8], toFloat32(2.1));
      expect(dev.fx[2], toFloat32(0.75));
      expect(c.sentParams, lessThan(10));

      final l = await c.getLoad();
      expect(l != null && l.budget > 0, isTrue);

      final errs = <({int target, int index})>[];
      final sub = c.qErrors.listen(errs.add);
      c.setParam(0, 120, 1);
      await sleep(60);
      expect(errs, [(target: 0, index: 120)]);
      await sub.cancel();

      await sleep(400);
      expect(keys, greaterThan(20));
      expect(motions, greaterThan(20));
      for (final id in ids) {
        expect(keyIds, contains(id));
      }
      expect(c.parser.stats.truncated, 0);

      await c.disconnect();
      expect(dev.streaming, isFalse, reason: 'disconnect stops the stream');
    });

    test('touch and key targets: list, write, clamp and errors', () async {
      final t = MockTransport();
      final c = StrisoClient(t);
      await c.connect();
      final g = (await c.getParams(Target.touch))!;
      expect(g.params.map((p) => p.name), ['pressure', 'velocity', 'tilt', 'bend', 'threshold']);
      final k = (await c.getParams(Target.keys))!;
      expect(k.params.length, 61);
      expect(k.params[60].name, firmwareKeyName(60));
      expect(firmwareKeyName(60), 'B_4');
      final errs = <({int target, int index})>[];
      final sub = c.qErrors.listen(errs.add);
      c.setParam(Target.keys, 5, 20); // out of range: the board answers Q err
      c.setParam(Target.touch, 0, 9); // clamps to 4
      c.setParam(Target.keys, 6, 1.25);
      await sleep(60);
      expect(errs, [(target: 3, index: 5)]);
      expect(t.board.touch[0], 4);
      expect(t.board.keyFactors[6], toFloat32(1.25));
      await sub.cancel();
      await c.disconnect();
    });

    test('replies to back to back commands are not mixed up', () async {
      final c = StrisoClient(MockTransport());
      await c.connect();
      c.startStream();
      final r = await Future.wait([c.listVoices(), c.getParams(0), c.getLoad(), c.getParams(1)]);
      expect((r[0] as List).length, greaterThan(10));
      expect((r[1] as ParamList).target, 0);
      expect((r[2] as LoadReading).blocks, greaterThanOrEqualTo(0));
      expect((r[3] as ParamList).target, 1);
      await c.disconnect();
    });

    test('engine slots: install with progress, listed, loads at the next start, erase', () async {
      final store = MockModuleStore();
      final own = MockBoard().voiceCount;
      var c = StrisoClient(MockTransport(board: MockBoard(modules: store)));
      await c.connect();
      expect(await c.listModuleSlots(), [for (var k = 2; k <= 6; k++) ModuleSlot(k, SlotState.empty)]);
      final pkg = mockModulePackage('sax', version: '0.3', padTo: 10000);
      final seen = <int>[];
      final r = await c.installModule(pkg, onProgress: (b, t) => seen.add(b));
      expect(r.ok, isTrue, reason: r.error);
      expect(r.error, isNull, reason: 'the progress crcs match what was sent');
      expect(r.tag, 'mock');
      expect([r.done!.slot, r.done!.id, r.done!.version, r.done!.abi], [2, 'sax', '0.3', mockEngineAbi]);
      expect(seen, [4096, 8192, 10000]);
      expect((await c.listModuleSlots())!.first, const ModuleSlot(2, SlotState.ok, id: 'sax', version: '0.3', abi: mockEngineAbi, bytes: 10000));
      expect((await c.listVoices()).length, own, reason: 'a new module loads at the next start');
      // another engine ABI: kept, listed disabled with the reason
      expect((await c.installModule(mockModulePackage('clarinet', abi: 9))).done?.slot, 3);
      final slots = (await c.listModuleSlots())!;
      expect(slots[1].state, SlotState.disabled);
      expect(slots[1].reason, 'abi 9, firmware has $mockEngineAbi');
      expect((await c.installModule([1, 2, 3])).error, 'not a package the mock reads');
      await c.disconnect();

      // the next start: the ok one's voices after the built-in engines
      c = StrisoClient(MockTransport(board: MockBoard(modules: store)));
      await c.connect();
      final voices = await c.listVoices();
      expect(voices.length, own + 4);
      expect(voices[own + 1].name, 'sax:alto sax');
      expect(await c.eraseModuleSlot(2), isNull);
      expect(await c.eraseModuleSlot(7), 'no slot 7 (slots 2..6)');
      expect((await c.listModuleSlots())!.first.state, SlotState.empty);
      await c.disconnect();

      // a firmware without a store refuses, and takes the bytes without reading any as a
      // command; one without slots at all (the stock firmware) does not answer
      final n = StrisoClient(MockTransport(board: MockBoard()));
      await n.connect();
      expect((await n.installModule(pkg)).error, 'no module store');
      expect(await n.listModuleSlots(), isEmpty);
      expect((await n.listVoices()).length, own, reason: 'the package was never sent as commands');
      await n.disconnect();
      final old = StrisoClient(MockTransport(board: MockBoard(stockFirmware: true)));
      await old.connect();
      expect(await old.listModuleSlots(timeout: const Duration(milliseconds: 150)), isNull);
      await old.disconnect();
    });

    test('module lines: the slot list, install and erase replies, crc32', () {
      expect(parseModuleSlots(['slot 2 empty']), isNull, reason: 'cut off');
      final l = parseModuleSlots([
        'slot 2 partial',
        'slot 3 accordion 0.1.0 2 61440 ok',
        'slot 4 trumpet 1.2 1 50000 disabled: abi 1, firmware has 2',
        'slot 5 - - - - disabled: header crc',
        'slot end',
      ])!;
      expect(l.map((s) => s.state), [SlotState.partial, SlotState.ok, SlotState.disabled, SlotState.disabled]);
      expect([l[1].id, l[1].version, l[1].abi, l[1].bytes], ['accordion', '0.1.0', 2, 61440]);
      expect(l[2].reason, 'abi 1, firmware has 2');
      expect([l[3].id, l[3].holdsEngine, l[3].reason], [null, false, 'header crc']);
      expect(parseModuleLine('m begin ok x86_64-windows 4'), isA<ModuleBegin>().having((m) => m.tag, 'tag', 'x86_64-windows').having((m) => m.free, 'free', 4));
      expect(parseModuleLine('m 4096 0a0b0c0d'), isA<ModuleProgress>().having((m) => m.crc, 'crc', 0x0a0b0c0d));
      expect(parseModuleLine('m ok 3 sax 1.0 2'), isA<ModuleDone>().having((m) => m.slot, 'slot', 3));
      expect(parseModuleLine('m erased 4'), isA<ModuleErased>());
      expect(parseModuleLine('m err no image for x86_64-windows'), isA<ModuleError>().having((m) => m.reason, 'reason', 'no image for x86_64-windows'));
      expect(parseModuleLine('slot end'), isNull);
      expect(crc32('123456789'.codeUnits), 0xCBF43926, reason: "zlib's check value");
      expect(crc32('456789'.codeUnits, crc: crc32('123'.codeUnits)), 0xCBF43926, reason: 'resumable');
      expect(moduleInstallCommand(List.filled(70000, 7)).sublist(0, 10), [0x53, 0x74, 0x63, 0x69, 0x73, 0x70, 0x11, 0x01, 0x00, 7]);
      expect(moduleEraseCommand(3), [0x53, 0x74, 0x63, 0x7a, 0x33]);
    });

    test('unplug is reported and pending commands resolve', () async {
      final t = MockTransport();
      final c = StrisoClient(t);
      await c.connect();
      UsbError? reason;
      c.closed.listen((e) => reason = e);
      final pending = c.getParams(0);
      t.unplug();
      final r = await pending;
      expect(r == null || r.complete == false, isTrue);
      await sleep(1);
      expect(reason?.code, UsbErrorCode.unplugged);
      expect(c.open, isFalse);
    });
  });

  test('layout: 61 keys, spelled from the line of fifths', () {
    expect(boardKeys.length, 61);
    expect(noteName(25).full, 'D4');
    expect(noteName(0).full, 'G♭5');
    expect(noteName(11).full, 'B5');
    expect(noteName(16).full, 'A♯5');
    expect(noteName(56).full, 'F2');
    expect(noteName(25, 12).full, 'D5');
    final ys = boardKeys.map((k) => k.y);
    expect((ys.reduce(math.max) + ys.reduce(math.min)).abs(), lessThan(1e-9));
    var minD = double.infinity;
    for (final a in boardKeys) {
      for (final b in boardKeys) {
        if (!identical(a, b)) minD = math.min(minD, math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)));
      }
    }
    expect(minD, inExclusiveRange(17, 19));
    expect(keyInfo(52).id, 52);
  });

  group('board byte pattern', () {
    test('headers 0x9F and 0x84, L reply split by frames, 64 byte packets', () {
      expect(motion(0)[0], 0x9f);
      expect(key(25, 1)[0], 0x84);
      for (final split in [false, true]) {
        var motions = 0, keys = 0;
        final lines = <String>[];
        final p = StreamParser(
          onMessage: (src, id, v, n) {
            if (src == Src.accel && n == 7) {
              motions++;
              expect(v[2], 1021);
            } else if (src == Src.dis && n == 4 && id == 25) {
              keys++;
              expect(v[3], 900);
            } else {
              fail('unexpected message $src $id $n');
            }
          },
          onLine: lines.add,
        );
        for (var s = 0; s < 3; s++) {
          packets(boardSecond(s > 0, split)).forEach(p.push);
        }
        expect(motions, 3 * 62);
        expect(keys, 2 * 62 * 11);
        expect(lines, List.filled(3, load.trim()));
        expect(p.stats.truncated, 0);
      }
    });

    test('the app connect sequence gets the stream through to the live state', () async {
      final (c, live) = await connectLikeTheApp(ScriptedBoard());
      final poll = Timer.periodic(const Duration(milliseconds: 200), (_) => c.getLoad());
      await sleep(800);
      poll.cancel();
      expect(live.messages, greaterThan(40));
      expect(live.motion.t, greaterThan(0));
      expect(live.motion.az, closeTo(1021 / 1024, 1e-9));
      expect(live.activeCount(), 1);
      expect(c.diagnostics().parser.truncated, 0);
      await c.disconnect();
    });

    test('the watchdog sends S again when only text arrives for 3 s', () async {
      final board = ScriptedBoard(ignoreFirstS: true);
      final (c, live) = await connectLikeTheApp(board);
      final events = <int>[];
      c.restreams.listen(events.add);
      final poll = Timer.periodic(const Duration(milliseconds: 500), (_) => c.getLoad());
      await sleep(4800);
      poll.cancel();
      expect(board.sCount, 2, reason: 'S sent a second time');
      expect(events.length, 1);
      expect(live.messages, greaterThan(20));
      expect(c.diagnostics().restarts, 1);
      await c.disconnect();
      expect(Cmd.streamOn(), [0x53, 0x74, 0x63, 0x53]);
    });
  });

  group('live state', () {
    test('idle frames with pressure noise never light a key or throw a ring', () {
      final live = LiveState();
      var s = 3;
      double r() => (s = (s * 16807) % 2147483647) / 2147483647;
      for (var k = 0; k < 5000; k++) {
        final id = keyIds[(r() * keyIds.length).floor()];
        frame(
          live,
          id,
          r() < 0.3 ? (r() * 31).floor() : 0,
          ((r() - 0.5) * 400).floor(),
          ((r() - 0.5) * 4000).floor(),
          ((r() - 0.5) * 4000).floor(),
          k * 2.0,
        );
      }
      expect(live.activeCount(), 0);
      expect(live.pres.every((p) => p == 0), isTrue);
      expect(live.x.every((p) => p == 0) && live.y.every((p) => p == 0), isTrue);
      expect(live.strikeT.every((t) => t < 0), isTrue);
      expect(live.releaseT.every((t) => t < 0), isTrue);
      expect(live.messages, 5000);
    });

    test('a press turns on above the threshold, holds through small dips and releases at zero', () {
      final live = LiveState();
      final on = (onLevel * 8191).ceil();
      frame(live, 25, on + 200, 3000, 100, -200, 10);
      expect(live.activeCount(), 1);
      expect(live.strikeT[25], 10);
      frame(live, 25, 20, 0, 0, 0, 20);
      expect(live.down[25], 1);
      expect(live.strikeT[25], 10, reason: 'no second strike');
      frame(live, 25, 0, -800, 0, 0, 30);
      expect(live.down[25], 0);
      expect(live.releaseT[25], 30);
      frame(live, 25, 3, 0, 0, 0, 40);
      expect(live.down[25], 0);
    });

    test('motion frames as the LSM6DSL path sends them: 1024 per g, 8192 = 500 dps', () {
      const ax = 1638, ay = -3277, az = 16384, gx = 6554, gy = 0, gz = -32768;
      int sh(int v) => v >> 2;
      final absG = math.sqrt(ax * ax + ay * ay + az * az) / 16384;
      final vals = [sh(ax ~/ 4), sh(ay ~/ 4), sh(az ~/ 4), sh((absG * 32768 / 8).truncate()), sh(gx), sh(gy), sh(gz)];
      final live = LiveState();
      final bytes = encodeMessage(0x13, 8, vals);
      expect((bytes[0] >> 3) & 0x0f, Src.accel);
      StreamParser(onMessage: (src, id, v, n) => live.apply(src, id, v, n, 5)).push(bytes);
      final m = live.motion;
      expect(m.az, closeTo(1, 0.002));
      expect(m.ax, closeTo(0.1, 0.002));
      expect(m.ay, closeTo(-0.2, 0.002));
      expect(m.abs, closeTo(absG, 0.002));
      expect(m.gx * 500, closeTo(100, 0.2));
      expect(m.gz, -1);
      expect(accPerG, 1024);
      expect(gyroFull, 8192);
    });

    test('transposition: as the board reports it (no guess from the octave buttons)', () {
      final live = LiveState();
      void ctl(int id, int v) => live.apply(Src.control, id, Int32List.fromList([v]), 1, 1);
      ctl(Idc.octUp, 1);
      ctl(Idc.octUp, 0);
      expect(live.transpose, 0, reason: 'the buttons alone say nothing: the board reports it');
      live.setTranspose(12);
      expect((live.transpose, live.transposeFifths), (12, 0));
      live.setTranspose(1);
      expect(live.transposeFifths, -5); // D -> Eb
      live.setTranspose(2);
      expect(live.transposeFifths, 2); // D -> E
      live.setTranspose(-1);
      expect(live.transposeFifths, 5); // D -> C#
    });
  });
}
