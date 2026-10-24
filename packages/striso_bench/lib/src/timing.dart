// Timestamp alignment: the audio library's timing marks (striso_audio.h, sa_mark) turned into
// "when did the device capture frame f", "when did the app get it", "when does output frame f
// play", and the offset between Dart's monotonic clock (Timeline.now, where the USB worker stamps
// the console's transfers) and the audio library's clock (sa_clock_us). On Windows both are
// QueryPerformanceCounter, so the offset is about 0; it is measured anyway.

import 'package:striso_audio/striso_audio.dart' show MarkKind, ProbeMark;

/// Offset (b - a, us) between two clocks read back to back: the reading of b bracketed by two of a
/// with the narrowest bracket of [n] tries.
({int offsetUs, int uncertaintyUs}) clockOffset(int Function() a, int Function() b, {int n = 64}) {
  var bestW = 1 << 62;
  var best = 0;
  for (var i = 0; i < n; i++) {
    final a1 = a();
    final bv = b();
    final a2 = a();
    final w = a2 - a1;
    if (w < bestW) {
      bestW = w;
      best = bv - (a1 + a2) ~/ 2;
    }
  }
  return (offsetUs: best, uncertaintyUs: (bestW + 1) ~/ 2);
}

/// The input side, from capture marks of one device session.
class CaptureTimeline {
  final double rate;
  final List<ProbeMark> packets = [], callbacks = [];
  int session = -1;
  CaptureTimeline(this.rate);

  /// Adds marks (other kinds and other sessions than the newest are dropped: frames restart).
  void add(Iterable<ProbeMark> marks) {
    for (final m in marks) {
      if (m.kind != MarkKind.capPacket && m.kind != MarkKind.capCallback) continue;
      if (m.session != session) {
        if (m.session < session) continue;
        session = m.session;
        packets.clear();
        callbacks.clear();
      }
      (m.kind == MarkKind.capPacket ? packets : callbacks).add(m);
    }
  }

  static ProbeMark? _containing(List<ProbeMark> l, double frame) {
    // binary search on the first frame (marks arrive in order)
    var lo = 0, hi = l.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final m = l[mid];
      if (frame < m.frame) {
        hi = mid - 1;
      } else if (frame >= m.frame + m.n) {
        lo = mid + 1;
      } else {
        return m;
      }
    }
    return null;
  }

  /// When the device captured frame [frame] (its own timestamp of its buffer, plus the frames
  /// before it in that buffer); null when the device gives no time.
  double? deviceUs(double frame) {
    final m = _containing(packets, frame);
    if (m == null || m.devUs == 0 || (m.flags & 2) != 0) return null;
    return m.devUs + (frame - m.frame) / rate * 1e6;
  }

  /// When the app's capture callback that carried frame [frame] started.
  int? callbackUs(double frame) => _containing(callbacks, frame)?.tUs;

  /// When the buffer with frame [frame] was handed over by the system (GetBuffer returned it).
  int? packetUs(double frame) => _containing(packets, frame)?.tUs;

  /// The first frame of the first callback at or after [tUs] (to search from), or null.
  int? frameAt(int tUs) {
    for (final m in callbacks) {
      if (m.tUs >= tUs) return m.frame;
    }
    return null;
  }

  int discontinuities() => packets.skip(1).where((m) => m.flags & 1 != 0).length;
}

/// The output side, from playback marks of one device session.
class PlayTimeline {
  final double rate;
  final List<ProbeMark> callbacks = [];
  int session = -1;
  PlayTimeline(this.rate);

  void add(Iterable<ProbeMark> marks) {
    for (final m in marks) {
      if (m.kind != MarkKind.playCallback) continue;
      if (m.session != session) {
        if (m.session < session) continue;
        session = m.session;
        callbacks.clear();
      }
      callbacks.add(m);
    }
  }

  /// When frame [frame] plays, by the output's clock in the mark nearest it (Windows: IAudioClock's
  /// position at its QPC time; macOS: Core Audio's presentation time); null when not reported.
  double? playUs(double frame) {
    ProbeMark? best;
    for (final m in callbacks.reversed) {
      if (m.devUs == 0) continue;
      if (m.frame <= frame) {
        best = m;
        break;
      }
      best = m;
    }
    if (best == null) return null;
    return best.devUs + (frame - best.devPos) / rate * 1e6;
  }

  /// Per callback: how long until its first frame plays (ms), by the output's clock.
  static double? firstFrameLatencyMs(ProbeMark m, double rate) {
    if (m.devUs == 0) return null;
    final playingAtCallback = m.devPos + (m.tUs - m.devUs) * rate / 1e6;
    return (m.frame - playingAtCallback) / rate * 1e3;
  }

  /// [firstFrameLatencyMs] of every callback that has the output's clock.
  List<double> firstFrameLatencies() => [for (final m in callbacks) ?firstFrameLatencyMs(m, rate)];
}
