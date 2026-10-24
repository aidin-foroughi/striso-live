// The latency marker: the PN table (against its LFSR and, when a firmware checkout has the
// marker, against usb_audio_core.h), detection in quiet, in loud audio, after a fractional delay
// (the passthrough's resampler), no false hits, and the console replies.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_bench/striso_bench.dart';
import 'package:test/test.dart';

Float32List _music(int frames, {int seed = 7, double level = 0.4}) {
  final x = Float32List(frames * 2);
  var s = seed;
  double rnd() {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff - 0.5;
  }

  for (var i = 0; i < frames; i++) {
    final t = i / 48000;
    final v = level * (0.5 * math.sin(2 * math.pi * 196 * t) + 0.3 * math.sin(2 * math.pi * 293.7 * t) + 0.2 * math.sin(2 * math.pi * 3520 * t)) + 0.05 * rnd();
    x[2 * i] = v;
    x[2 * i + 1] = 0.9 * v;
  }
  return x;
}

/// The firmware's table, when the checkout has it (null otherwise).
List<int>? firmwarePn() {
  final env = Platform.environment['STRISO_FW_DIR'];
  final c = [
    ?env,
    '../../../striso-control-firmware',
    '../../../worktrees/fw-int',
  ];
  for (final d in c) {
    final f = File('$d/src/usb/usb_audio_core.h');
    if (!f.existsSync()) continue;
    final m = RegExp(r'ua_mark_pn\[UA_MARK_FRAMES\]\s*=\s*\{([^}]*)\}').firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1)!.split(',').map((e) => int.parse(e.trim())).toList();
  }
  return null;
}

void main() {
  test('the PN is the LFSR x^5 + x^3 + 1 plus one chip, balanced, small sidelobes', () {
    expect(markPn, markPnFromLfsr());
    expect(markPn.length, markFrames);
    expect(markPn.reduce((a, b) => a + b).abs(), lessThanOrEqualTo(2));
    var side = 0;
    for (var k = 1; k < markFrames; k++) {
      var s = 0;
      for (var i = 0; i + k < markFrames; i++) {
        s += markPn[i] * markPn[i + k];
      }
      side = math.max(side, s.abs());
    }
    expect(side, lessThanOrEqualTo(5));
  });

  final fw = firmwarePn();
  test('the PN matches the firmware (usb_audio_core.h)', () {
    expect(fw, markPn);
  }, skip: fw == null ? 'no firmware checkout with the marker (STRISO_FW_DIR, ../striso-control-firmware)' : null);

  test('found exactly in silence and in loud audio, right channel only', () {
    for (final level in [0.0, 0.4, 0.9]) {
      final x = _music(4800, level: level);
      writeMarker(x, 1234);
      final h = findMarker(channelOf(x, 1))!;
      expect(h.at, closeTo(1234, 0.05));
      expect(h.score, closeTo(1, 1e-6));
      expect(h.amplitude, closeTo(0.1, 1e-6));
      // the left channel never has it
      expect(findMarker(channelOf(x, 0)), isNull);
    }
  });

  test('16-bit and float rounding keep it exact enough', () {
    final x = _music(2000);
    writeMarker(x, 500, amp: 3277 / 32768);
    final h = findMarker(channelOf(x, 1))!;
    expect(h.at, closeTo(500, 0.05));
    expect(h.score, greaterThan(0.999));
  });

  test('after a fractional delay (resampled) it is found to a fraction of a frame', () {
    for (final d in [0.25, 0.5, 0.8]) {
      final src = Float32List(4000 * 2);
      writeMarker(src, 1000);
      final r = channelOf(src, 1);
      // band-limited fractional delay: windowed sinc, 32 taps each side
      final y = Float32List(r.length);
      for (var i = 40; i < r.length - 40; i++) {
        var acc = 0.0;
        for (var k = -32; k <= 32; k++) {
          final t = k - d;
          final sinc = t == 0 ? 1.0 : math.sin(math.pi * 0.94 * t) / (math.pi * t);
          final w = 0.5 + 0.5 * math.cos(math.pi * k / 33);
          acc += r[i - k] * sinc * w;
        }
        y[i] = acc;
      }
      final h = findMarker(y)!;
      expect(h.at, closeTo(1000 + d, 0.35), reason: 'delay $d');
      expect(h.score, greaterThan(0.85));
    }
  });

  test('no false hit in 10 s of music and noise, nor in a full-scale square wave', () {
    expect(findMarker(channelOf(_music(480000), 1)), isNull);
    final sq = Float32List(48000);
    for (var i = 0; i < sq.length; i++) {
      sq[i] = (i ~/ 7).isEven ? 0.1 : -0.1;
    }
    expect(findMarker(sq), isNull);
  });

  test('the level gate: a marker at full scale or at -40 dBFS is not taken', () {
    for (final amp in [1.0, 0.01]) {
      final x = Float32List(2000 * 2);
      writeMarker(x, 300, amp: amp);
      expect(findMarker(channelOf(x, 1)), isNull, reason: 'amp $amp');
    }
  });

  test('search window', () {
    final x = Float32List(3000 * 2);
    writeMarker(x, 2000);
    final r = channelOf(x, 1);
    expect(findMarker(r, from: 0, to: 1500), isNull);
    expect(findMarker(r, from: 1500)!.at, 2000);
  });

  test('the console replies parse', () {
    final m = MarkerReply.parse('usb audio marker 7: frame 1234 index 0 level 101 target 96, bus 2345 us after rx (rx frame 1232), right 32 frames -20 dBFS 24 bit')!;
    expect((m.seq, m.sent, m.frame, m.index, m.level, m.target, m.busUs, m.rxFrame, m.frames, m.bits), (7, true, 1234, 0, 101, 96, 2345, 1232, 32, 24));
    expect(MarkerReply.parse('usb audio marker 8: lost (the host did not fetch its packet)')!.status, 'lost');
    expect(MarkerReply.parse('usb audio marker 9: not streaming')!.status, 'not streaming');
    expect(MarkerReply.parse('usb audio marker: busy')!.status, 'busy');
    expect(MarkerReply.parse('usb audio target 96 frames (2000 us)'), isNull);
    expect(parseEcho('usb audio echo: held 1234 us'), 1234);
    expect(parseEcho('usb audio marker 1: not streaming'), isNull);
  });
}
