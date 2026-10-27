// Live instrument state from the key stream: per key pressure, velocity and tilt, strikes and
// releases, peaks, control buttons, motion sensor and a best-effort transposition from the octave
// buttons.

import 'dart:typed_data';

import 'layout.dart';
import 'protocol.dart';

/// Pressure hysteresis for showing a key as pressed (full scale 1): the board also streams frames
/// for untouched keys (hundreds per second), so noise near zero must not light a key.
const double onLevel = 0.004;
const double offLevel = 0.001;

class Motion {
  double ax = 0, ay = 0, az = 1, abs = 1, gx = 0, gy = 0, gz = 0;
  double t = -1e9;
}

class LiveState {
  // per button id, sized by the board's key layout (no layout yet: no keys)
  var pres = Float32List(0); // shown pressure: 0 unless the key is on
  var raw = Float32List(0); // pressure as received
  var down = Uint8List(0);
  var onT = Float64List(0);
  var peak = Float32List(0); // highest pressure of the press in progress
  var lastPeak = Float32List(0); // highest pressure of the last finished press
  var lastPeakT = Float64List(0);
  var vpres = Float32List(0);
  var x = Float32List(0);
  var y = Float32List(0);
  var strikeT = Float64List(0);
  var strikeA = Float32List(0);
  var releaseT = Float64List(0);
  var releaseA = Float32List(0);
  KeyLayout? _layout;

  LiveState([KeyLayout? layout]) {
    if (layout != null) this.layout = layout;
  }

  /// The board's keys as it reports them (StcG); null until a board (or the last one, remembered)
  /// has. Key messages for buttons beyond its button count are dropped.
  KeyLayout? get layout => _layout;
  set layout(KeyLayout? l) {
    _layout = l;
    final n = l?.buttons ?? 0;
    if (n == pres.length) return;
    pres = Float32List(n);
    raw = Float32List(n);
    down = Uint8List(n);
    onT = Float64List(n)..fillRange(0, n, -1e9);
    peak = Float32List(n);
    lastPeak = Float32List(n);
    lastPeakT = Float64List(n)..fillRange(0, n, -1e9);
    vpres = Float32List(n);
    x = Float32List(n);
    y = Float32List(n);
    strikeT = Float64List(n)..fillRange(0, n, -1e9);
    strikeA = Float32List(n);
    releaseT = Float64List(n)..fillRange(0, n, -1e9);
    releaseA = Float32List(n);
  }

  final controls = Uint8List(16);
  final controlT = Float64List(16)..fillRange(0, 16, -1e9);
  final motion = Motion();
  int transpose = 0; // semitones
  int transposeFifths = 0; // spelling shift on the line of fifths (a semitone up is 5 fifths down)
  int messages = 0;
  double rate = 0;
  int _rateCount = 0;
  double _rateT = 0;
  final pressListeners = <void Function(int id, double now)>[];
  final releaseListeners = <void Function(int id, double now)>[];
  final controlListeners = <void Function(int id, bool down, bool before)>[];

  void clear() {
    pres.fillRange(0, pres.length, 0);
    raw.fillRange(0, raw.length, 0);
    down.fillRange(0, down.length, 0);
    vpres.fillRange(0, vpres.length, 0);
    x.fillRange(0, x.length, 0);
    y.fillRange(0, y.length, 0);
    controls.fillRange(0, 16, 0);
  }

  /// Every stream message; [v] holds 14 bit ints (a reused array). [now] in milliseconds.
  void apply(int src, int id, Int32List v, int n, double now) {
    messages++;
    _rateCount++;
    if (src == Src.dis && n == 4 && id < pres.length) {
      // older firmware sent pressure / 2^11 unclamped, so 1.0 and more wrapped to negative
      final pv = v[0] < -2048 ? v[0] + 16384 : v[0];
      final r = pv / fullScale, vp = v[1] / fullScale;
      final was = down[id] == 1;
      final on = was ? r > offLevel : r >= onLevel;
      raw[id] = r;
      if (on && r > peak[id]) peak[id] = r;
      if (on && !was) {
        onT[id] = now;
        for (final f in pressListeners) {
          f(id, now);
        }
        strikeT[id] = now;
        strikeA[id] = vp > 0.15 ? vp : 0.15;
      } else if (on && vp > 0.25 && vp > vpres[id] + 0.15 && now - strikeT[id] > 90) {
        strikeT[id] = now; // a new strike while held
        strikeA[id] = vp;
      } else if (!on && was) {
        lastPeak[id] = peak[id];
        lastPeakT[id] = now;
        peak[id] = 0;
        for (final f in releaseListeners) {
          f(id, now);
        }
        releaseT[id] = now;
        releaseA[id] = (-vp).clamp(0.1, 1.0);
      }
      down[id] = on ? 1 : 0;
      pres[id] = on ? r : 0;
      vpres[id] = on || was ? vp : 0;
      x[id] = on ? v[2] / fullScale : 0;
      y[id] = on ? v[3] / fullScale : 0;
    } else if (src == Src.control && n >= 1 && id < 16) {
      final isDown = v[0] != 0;
      final before = controls[id] == 1;
      controls[id] = isDown ? 1 : 0;
      controlT[id] = now;
      for (final f in controlListeners) {
        f(id, isDown, before);
      }
    } else if (src == Src.accel && n == 7) {
      motion
        ..ax = v[0] / accPerG
        ..ay = v[1] / accPerG
        ..az = v[2] / accPerG
        ..abs = v[3] / accPerG
        ..gx = v[4] / gyroFull
        ..gy = v[5] / gyroFull
        ..gz = v[6] / gyroFull
        ..t = now;
    }
  }

  /// The transposition as the board reports it (StcY transpose, in semitones): the labels follow
  /// it. A semitone moves the spelling 5 fifths down (D -> Eb -> E), as the firmware's semitone
  /// step is 3 octaves less 5 fifths; kept in a sane range.
  void setTranspose(int semitones) {
    transpose = semitones;
    var f = -5 * (semitones % 12);
    while (f > 5) {
      f -= 12;
    }
    while (f < -6) {
      f += 12;
    }
    transposeFifths = f;
  }

  void resetTranspose() {
    transpose = 0;
    transposeFifths = 0;
  }

  void tickRate(double now) {
    if (now - _rateT >= 500) {
      rate = _rateCount * 1000 / (now - _rateT == 0 ? 1 : now - _rateT);
      _rateCount = 0;
      _rateT = now;
    }
  }

  int activeCount() {
    var n = 0;
    for (final d in down) {
      n += d;
    }
    return n;
  }
}
