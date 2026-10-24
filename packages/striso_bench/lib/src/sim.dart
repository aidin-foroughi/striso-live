// The usb-in measurement without hardware: a fixed model of the board and the input device makes
// the timing marks and the input audio (a synth-like signal with the marker written in, as the
// firmware does), and the same detection and summary code as on hardware turns them into the
// report. Deterministic: the numbers are the model's, so CI can check the whole chain.
//
// Model: 48 kHz; the input device delivers buffers of [buffer] frames, each stamped with the time
// its first frame was captured and handed over [handoverUs] after its last frame; the driver
// stamps a frame [driverUs] after it was on the bus; the console's transit is 300 us each way
// (the board holds an echo 1450 us); the board's command-to-bus time steps through 1.2..2.2 ms.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_audio/striso_audio.dart' show MarkKind, ProbeMark;

import 'bench.dart';
import 'console.dart';
import 'marker.dart';
import 'timing.dart';

Map<String, Object?> simUsbIn({int n = 50, bool exclusive = true}) {
  const rate = 48000.0;
  final buffer = exclusive ? 144 : 480;
  final handoverUs = exclusive ? 400 : 1500;
  const driverUs = 1000, t0 = 0;
  const total = 48000 * 6;
  final x = Float32List(total * 2);
  var seed = 1;
  double rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff - 0.5;
  }

  for (var i = 0; i < total; i++) {
    final s = 0.3 * math.sin(2 * math.pi * 220 * i / rate) + 0.05 * rnd();
    x[2 * i] = s;
    x[2 * i + 1] = s * 0.8;
  }
  double devUs(num frame) => t0 + frame / rate * 1e6;
  const owdUs = 300.0;
  final exchanges = <(Exchange<MarkerReply>, int)>[];
  for (var i = 0; i < n; i++) {
    final sent = 200000 + i * 90000;
    final busUs = 1200 + (i * 137) % 1000;
    final bus = sent + owdUs + busUs;
    final frame = ((bus + driverUs - t0) * rate / 1e6).ceil();
    writeMarker(x, frame);
    final r = MarkerReply(i + 1, 'sent', frame: i, index: 0, level: 96 + (i * 5) % 30, target: 96, busUs: busUs, rxFrame: 0, frames: 32, bits: 24);
    exchanges.add((Exchange(r, sent, sent + 150, sent + 3800), frame));
  }
  final cap = CaptureTimeline(rate);
  final marks = <ProbeMark>[];
  for (var f = 0; f + buffer <= total; f += buffer) {
    final handed = (devUs(f + buffer) + handoverUs).round();
    marks.add(ProbeMark(MarkKind.capPacket, buffer, 1, 0, f, handed, f, devUs(f).round(), 0));
    marks.add(ProbeMark(MarkKind.capCallback, buffer, 1, 0, f, handed + 20, 0, 0, 15));
  }
  cap.add(marks);
  final r = channelOf(x, 1);
  final trials = <UsbInTrial>[];
  for (final (e, _) in exchanges) {
    final from = cap.frameAt(e.sentUs)!;
    final h = findMarker(r, from: from, to: from + 12000);
    final f = h?.at;
    trials.add(UsbInTrial(e.sentUs, e.writtenUs, e.replyUs, e.reply!, f, h?.score, f == null ? null : cap.callbackUs(f)?.toDouble(), f == null ? null : cap.deviceUs(f), owdUs));
  }
  final rtt = List<double>.generate(20, (_) => 3.2);
  final transit = List<double>.generate(20, (_) => 2 * owdUs / 1000);
  return {
    'mode': exclusive ? 'exclusive' : 'shared',
    'simulated': true,
    'capture': {'exclusive': exclusive, 'buffer_frames': buffer, 'rate': rate.round()},
    ...usbInSummary(trials, rttMs: rtt, transitMs: transit, owdUs: owdUs),
  };
}
