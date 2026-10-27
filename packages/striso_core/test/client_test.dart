// The client without a board: the engine-slot lines, a firmware that doesn't answer, an unplug; a
// scripted board's byte pattern end to end through the stream; the live state. The client against
// a board: packages/striso_virtual/test/client_test.dart (the virtual board).
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/silent_transport.dart';

/// The board's keys (StcG, as the firmware reports them): the live state's buttons.
final keyLayout = fixtureKeyLayout();

/// The key at 0 0 (D4): the key the scripted board plays.
final dKey = keyLayout.keys.singleWhere((k) => k.c0 == 0 && k.c1 == 0).id;

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
        out.addAll(key(dKey, 2000 + 10 * j));
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
          ..addAll(key(dKey, 3000));
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
  final live = LiveState(keyLayout);
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
  group('without a board', () {
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

    test('a firmware without engine slots (the stock one) does not answer Stco', () async {
      final c = StrisoClient(SilentTransport());
      await c.connect();
      expect(await c.listModuleSlots(timeout: const Duration(milliseconds: 150)), isNull);
      await c.disconnect();
    });

    test('unplug is reported and pending commands resolve', () async {
      final t = SilentTransport();
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

  group('board byte pattern', () {
    test('headers 0x9F and 0x84, L reply split by frames, 64 byte packets', () {
      expect(motion(0)[0], 0x9f);
      expect(key(dKey, 1)[0], 0x84);
      for (final split in [false, true]) {
        var motions = 0, keys = 0;
        final lines = <String>[];
        final p = StreamParser(
          onMessage: (src, id, v, n) {
            if (src == Src.accel && n == 7) {
              motions++;
              expect(v[2], 1021);
            } else if (src == Src.dis && n == 4 && id == dKey) {
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
      final live = LiveState(keyLayout);
      var s = 3;
      double r() => (s = (s * 16807) % 2147483647) / 2147483647;
      for (var k = 0; k < 5000; k++) {
        final ids = keyLayout.keyIds;
        final id = ids[(r() * ids.length).floor()];
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
      final live = LiveState(keyLayout);
      final on = (onLevel * 8191).ceil();
      frame(live, dKey, on + 200, 3000, 100, -200, 10);
      expect(live.activeCount(), 1);
      expect(live.strikeT[dKey], 10);
      frame(live, dKey, 20, 0, 0, 0, 20);
      expect(live.down[dKey], 1);
      expect(live.strikeT[dKey], 10, reason: 'no second strike');
      frame(live, dKey, 0, -800, 0, 0, 30);
      expect(live.down[dKey], 0);
      expect(live.releaseT[dKey], 30);
      frame(live, dKey, 3, 0, 0, 0, 40);
      expect(live.down[dKey], 0);
    });

    test('motion frames as the LSM6DSL path sends them: 1024 per g, 8192 = 500 dps', () {
      const ax = 1638, ay = -3277, az = 16384, gx = 6554, gy = 0, gz = -32768;
      int sh(int v) => v >> 2;
      final absG = math.sqrt(ax * ax + ay * ay + az * az) / 16384;
      final vals = [sh(ax ~/ 4), sh(ay ~/ 4), sh(az ~/ 4), sh((absG * 32768 / 8).truncate()), sh(gx), sh(gy), sh(gz)];
      final live = LiveState(keyLayout);
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
      final live = LiveState(keyLayout);
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
