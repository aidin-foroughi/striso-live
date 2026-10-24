// The measurement math: statistics, clock alignment, the timelines built from the audio
// library's marks, the usb-in summary (the simulated board, deterministic) and the report schema.
import 'package:striso_audio/striso_audio.dart' show MarkKind, ProbeMark;
import 'package:striso_bench/striso_bench.dart';
import 'package:test/test.dart';

ProbeMark _m(int kind, int frame, int n, int tUs, {int session = 1, int devPos = 0, int devUs = 0, int flags = 0}) =>
    ProbeMark(kind, n, session, flags, frame, tUs, devPos, devUs, 0);

void main() {
  group('stats', () {
    test('min, median, p95 (nearest rank), max, mean', () {
      final s = Stats.of([5, 1, 4, 2, 3])!;
      expect((s.n, s.min, s.median, s.p95, s.max, s.mean), (5, 1.0, 3.0, 5.0, 5.0, 3.0));
      final e = Stats.of(List.generate(100, (i) => i + 1))!;
      expect((e.median, e.p95), (50.5, 95.0));
      expect(Stats.of([]), isNull);
      expect(Stats.of([double.nan, 2])!.n, 1);
    });
  });

  group('clock alignment', () {
    test('the offset between two clocks, from the narrowest bracket', () {
      var t = 1000;
      var jitter = 0;
      int a() => t += 3 + (jitter++ % 5 == 0 ? 40 : 0);
      int b() => t + 250000;
      final o = clockOffset(a, b);
      expect(o.offsetUs, inInclusiveRange(250000 - 2, 250000 + 2));
      expect(o.uncertaintyUs, lessThanOrEqualTo(4));
    });
  });

  group('capture timeline', () {
    final c = CaptureTimeline(48000)
      ..add([
        _m(MarkKind.capPacket, 0, 144, 3500, devPos: 0, devUs: 0),
        _m(MarkKind.capCallback, 0, 144, 3520),
        _m(MarkKind.capPacket, 144, 144, 6500, devPos: 144, devUs: 3000),
        _m(MarkKind.capCallback, 144, 144, 6520),
        _m(MarkKind.capPacket, 288, 144, 9500, devPos: 288, devUs: 6000, flags: 1),
        _m(MarkKind.capCallback, 288, 144, 9520),
      ]);
    test('device time of a frame: its buffer\'s time plus the frames before it', () {
      expect(c.deviceUs(144), 3000);
      expect(c.deviceUs(144 + 48), closeTo(4000, 1e-9));
      expect(c.deviceUs(10), isNull); // the device gave no time
      expect(c.deviceUs(5000), isNull);
    });
    test('the callback that carried a frame, and where to search from', () {
      expect(c.callbackUs(150.5), 6520);
      expect(c.packetUs(300), 9500);
      expect(c.frameAt(6000), 144);
      expect(c.frameAt(99999), isNull);
      expect(c.discontinuities(), 1);
    });
    test('a new session restarts the frames', () {
      final d = CaptureTimeline(48000)
        ..add([_m(MarkKind.capCallback, 0, 144, 100)])
        ..add([_m(MarkKind.capCallback, 0, 144, 900, session: 2), _m(MarkKind.capCallback, 144, 144, 50, session: 1)]);
      expect(d.callbacks.length, 1);
      expect(d.callbackUs(10), 900);
    });
  });

  group('play timeline', () {
    test('first-frame latency from the output clock: written ahead of what plays', () {
      // at 10000 us frame 960 plays; the callback at 10500 writes from frame 1200
      final m = _m(MarkKind.playCallback, 1200, 144, 10500, devPos: 960, devUs: 10000);
      // playing at the callback: 960 + 0.5 ms * 48 = 984; 1200 - 984 = 216 frames = 4.5 ms
      expect(PlayTimeline.firstFrameLatencyMs(m, 48000), closeTo(4.5, 1e-9));
      final p = PlayTimeline(48000)..add([m]);
      expect(p.playUs(1200), closeTo(10000 + 240 / 48 * 1000, 1e-6));
      expect(p.firstFrameLatencies(), [closeTo(4.5, 1e-9)]);
    });
    test('macOS: the mark carries the buffer\'s own presentation time', () {
      final m = _m(MarkKind.playCallback, 4800, 512, 20000, devPos: 4800, devUs: 31000);
      expect(PlayTimeline.firstFrameLatencyMs(m, 48000), closeTo(11, 1e-9));
    });
    test('no clock: no number', () {
      expect(PlayTimeline.firstFrameLatencyMs(_m(MarkKind.playCallback, 0, 128, 5), 48000), isNull);
      expect((PlayTimeline(48000)..add([_m(MarkKind.playCallback, 0, 128, 5)])).playUs(10), isNull);
    });
  });

  group('usb-in', () {
    test('the board part as the app reckons it', () {
      expect(boardPartMs(96), closeTo(72 / 48 + 1.23, 1e-9));
      expect(boardPartMs(10), closeTo(1.23, 1e-9));
    });
    test('simulated board, exclusive: deterministic numbers through the real detection', () {
      final r = simUsbIn(n: 30);
      expect(r['markers'], containsPair('found', 30));
      final lat = r['usb_in_ms'] as Map;
      // bus + 1 ms driver -> the frame's buffer ends <= 3 ms later, + 0.4 ms handover + 20 us
      expect(lat['min'] as num, greaterThan(1.4));
      expect(lat['max'] as num, lessThan(4.5));
      expect(simUsbIn(n: 30), r, reason: 'deterministic');
      final drv = r['bus_to_device_timestamp_ms'] as Map;
      expect(drv['median'] as num, closeTo(1.0, 0.03));
    });
    test('simulated board, shared: 10 ms buffers', () {
      final r = simUsbIn(n: 20, exclusive: false);
      expect((r['usb_in_ms'] as Map)['median'] as num, greaterThan((simUsbIn(n: 20)['usb_in_ms'] as Map)['median'] as num));
    });
  });

  group('report', () {
    Map<String, Object?> good() => {
      'schema': schemaId,
      'command': 'usb-in',
      'started': DateTime(2026, 10, 24).toIso8601String(),
      'duration_s': 12.5,
      'host': {'os': 'windows', 'sim': true},
      'board': {'console': 'simulated board', 'version': 'sim'},
      'results': {'usb_in_exclusive': simUsbIn(n: 10)},
      'checks': [for (final c in checksOf({'usb_in_exclusive': simUsbIn(n: 10)})) c.toJson()],
      'ok': true,
      'notes': <String>[],
    };
    test('a report of the simulated run is valid', () {
      expect(validateReport(good()), isEmpty);
    });
    test('problems are named', () {
      expect(validateReport(42), ['not an object']);
      expect(validateReport({...good(), 'schema': 'x'}), contains('"schema" is not $schemaId'));
      expect(validateReport({...good()}..remove('checks')), contains('missing "checks"'));
      expect(
        validateReport({
          ...good(),
          'results': {
            'x': {
              'lat': {'n': 1, 'min': 5, 'median': 3, 'p95': 3, 'max': 4, 'mean': 3},
            },
          },
        }),
        contains('results.x.lat: min <= median <= max fails'),
      );
    });
    test('checks: the bounds the hardware suite asserts', () {
      final c = checksOf({
        'usb_in_exclusive': {
          'usb_in_ms': {'median': 9.0},
          'markers': {'found': 50, 'sent': 50},
        },
        'through': {'board_underruns': 1, 'board_polls': 10, 'silence_violations': 0},
        'stats': {'audio_driver': 'usbaudio', 'midi_port': null, 'audio_input': 'Line (Striso Synth)'},
      });
      String s(String n) => '${c.firstWhere((x) => x.name == n).ok}';
      expect(s('usb_in_exclusive: median latency'), 'false');
      expect(s('usb_in_exclusive: markers found'), 'true');
      expect(s('through: board underruns'), 'false');
      expect(s('through: output stayed silent'), 'true');
      expect(s('stats: audio driver'), 'false');
      expect(s('stats: MIDI port present'), 'false');
      expect(s('stats: audio input present'), 'true');
    });
    test('at: a value by its path', () {
      expect(at({'a': {'b': [1, 2, 3]}}, 'a.b.2'), 3);
      expect(at({'a': 1}, 'a.b'), isNull);
    });
  });
}
