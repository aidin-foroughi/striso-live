// The firmware's USB audio latency marker (console Stcl1, usb_audio_core.h ua_mark_pn): 32 chips
// of a 5-bit maximal-length sequence (x^5 + x^3 + 1) plus one, at -20 dBFS (0.1 of full scale),
// over the right channel of one packet. Found by normalised correlation, so it is found in any
// audio the synth plays on the left and before it on the right, exactly (score 1) in a bit-exact
// capture and slightly smeared (score ~0.9+) after the passthrough's resampler.

import 'dart:math' as math;
import 'dart:typed_data';

/// usb_audio_core.h, ua_mark_pn (the firmware cross-check test compares them).
const markPn = <int>[1, -1, -1, -1, -1, 1, -1, -1, 1, -1, 1, 1, -1, -1, 1, 1, 1, 1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, -1, 1, -1, 1];
const markAmp = 0.1;
const markFrames = 32;

/// The 5-bit LFSR the firmware's table came from (x^5 + x^3 + 1, seed 00001), plus a final +1.
List<int> markPnFromLfsr() {
  var s = [0, 0, 0, 0, 1];
  final out = <int>[];
  for (var i = 0; i < 31; i++) {
    out.add(s[4] == 1 ? 1 : -1);
    final nb = s[4] ^ s[2];
    s = [nb, ...s.take(4)];
  }
  return [...out, 1];
}

class MarkerHit {
  /// Where the marker's first chip is, in frames from the start of the searched channel
  /// (fractional: parabolic interpolation of the correlation peak).
  final double at;

  /// Normalised correlation, -1..1 (1: exactly the marker, at any level).
  final double score;

  /// The marker's level as found (0.1 when untouched).
  final double amplitude;
  const MarkerHit(this.at, this.score, this.amplitude);

  @override
  String toString() => 'MarkerHit(at ${at.toStringAsFixed(2)}, score ${score.toStringAsFixed(3)}, amp ${amplitude.toStringAsFixed(3)})';
}

/// One channel of interleaved stereo.
Float32List channelOf(Float32List stereo, int channel) {
  final n = stereo.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = stereo[2 * i + channel];
  }
  return out;
}

/// The best marker in x[from, to) whose normalised correlation is at least [minScore] and whose
/// level is within [minAmp, maxAmp] (so a quiet stretch of noise or a loud chord does not pass),
/// or null.
MarkerHit? findMarker(Float32List x, {int from = 0, int? to, double minScore = 0.85, double minAmp = 0.05, double maxAmp = 0.2, bool fractional = true}) {
  final end = math.min(to ?? x.length, x.length) - markFrames;
  var best = -1;
  var bestScore = minScore;
  double corr(int i) {
    var c = 0.0;
    for (var k = 0; k < markFrames; k++) {
      c += markPn[k] * x[i + k];
    }
    return c;
  }

  for (var i = math.max(0, from); i <= end; i++) {
    // cheap gate: the first chip is about +amp
    final c = corr(i);
    if (c <= 0) continue;
    var e = 0.0;
    for (var k = 0; k < markFrames; k++) {
      e += x[i + k] * x[i + k];
    }
    if (e <= 0) continue;
    final score = c / math.sqrt(markFrames * e);
    final amp = c / markFrames;
    if (score > bestScore && amp >= minAmp && amp <= maxAmp) {
      bestScore = score;
      best = i;
    }
  }
  if (best < 0) return fractional ? _findFractional(x, math.max(0, from), end, minScore, minAmp, maxAmp) : null;
  final c0 = corr(best);
  var at = best.toDouble();
  if (best > 0 && best + 1 <= end) {
    final cm = corr(best - 1), cp = corr(best + 1);
    final d = cm - 2 * c0 + cp;
    if (d < 0) at += (0.5 * (cm - cp) / d).clamp(-0.5, 0.5);
  }
  return MarkerHit(at, bestScore, c0 / markFrames);
}

/// The marker as a band-limited signal delayed by [frac] of a frame (0 <= frac < 1): what a
/// resampler makes of it (windowed sinc, cutoff 0.94 of Nyquist like the passthrough's).
/// Index j of the result is frame j - [_pad] relative to the first chip.
const _pad = 12, _fracSteps = 8;
final List<Float64List> _templates = [
  for (var s = 0; s < _fracSteps; s++)
    () {
      final f = s / _fracSteps;
      final t = Float64List(markFrames + 2 * _pad);
      for (var j = 0; j < t.length; j++) {
        var acc = 0.0;
        for (var k = 0; k < markFrames; k++) {
          final d = j - _pad - k - f;
          final sinc = d == 0 ? 0.94 : math.sin(math.pi * 0.94 * d) / (math.pi * d);
          final w = d.abs() >= _pad ? 0.0 : 0.5 + 0.5 * math.cos(math.pi * d / _pad);
          acc += markPn[k] * sinc * w;
        }
        t[j] = acc * markAmp / 0.94;
      }
      return t;
    }(),
];

MarkerHit? _findFractional(Float32List x, int from, int end, double minScore, double minAmp, double maxAmp) {
  MarkerHit? best;
  var bestScore = minScore;
  for (var s = 0; s < _fracSteps; s++) {
    final t = _templates[s];
    var tt = 0.0;
    for (final v in t) {
      tt += v * v;
    }
    for (var i = math.max(from, _pad); i <= end && i + markFrames + _pad <= x.length; i++) {
      var c = 0.0, e = 0.0;
      for (var j = 0; j < t.length; j++) {
        final v = x[i - _pad + j];
        c += t[j] * v;
        e += v * v;
      }
      if (c <= 0 || e <= 0) continue;
      final score = c / math.sqrt(tt * e);
      final amp = c / tt * markAmp;
      if (score > bestScore && amp >= minAmp && amp <= maxAmp) {
        bestScore = score;
        best = MarkerHit(i + s / _fracSteps, score, amp);
      }
    }
  }
  return best;
}

/// Writes the marker over channel [channel] of stereo x at frame [at] (the simulated board, tests).
void writeMarker(Float32List stereo, int at, {int channel = 1, double amp = markAmp}) {
  for (var k = 0; k < markFrames; k++) {
    final i = 2 * (at + k) + channel;
    if (i < stereo.length) stereo[i] = (markPn[k] * amp).toDouble();
  }
}
