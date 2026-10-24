// Live instrument state from the key stream: per key pressure, velocity and tilt, strikes and
// releases, peaks, control buttons, motion sensor and a best-effort transposition from the octave
// buttons. Port of tools/app/js/live.js.

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
  final pres = Float32List(buttonCount); // shown pressure: 0 unless the key is on
  final raw = Float32List(buttonCount); // pressure as received
  final down = Uint8List(buttonCount);
  final onT = Float64List(buttonCount)..fillRange(0, buttonCount, -1e9);
  final peak = Float32List(buttonCount); // highest pressure of the press in progress
  final lastPeak = Float32List(buttonCount); // highest pressure of the last finished press
  final lastPeakT = Float64List(buttonCount)..fillRange(0, buttonCount, -1e9);
  final vpres = Float32List(buttonCount);
  final x = Float32List(buttonCount);
  final y = Float32List(buttonCount);
  final strikeT = Float64List(buttonCount)..fillRange(0, buttonCount, -1e9);
  final strikeA = Float32List(buttonCount);
  final releaseT = Float64List(buttonCount)..fillRange(0, buttonCount, -1e9);
  final releaseA = Float32List(buttonCount);
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
    pres.fillRange(0, buttonCount, 0);
    raw.fillRange(0, buttonCount, 0);
    down.fillRange(0, buttonCount, 0);
    vpres.fillRange(0, buttonCount, 0);
    x.fillRange(0, buttonCount, 0);
    y.fillRange(0, buttonCount, 0);
    controls.fillRange(0, 16, 0);
  }

  /// Every stream message; [v] holds 14 bit ints (a reused array). [now] in milliseconds.
  void apply(int src, int id, Int32List v, int n, double now) {
    messages++;
    _rateCount++;
    if (src == Src.dis && n == 4 && id < buttonCount) {
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
