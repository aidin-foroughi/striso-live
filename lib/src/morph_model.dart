// Morph pad model: up to four captured sounds in the corners of an XY pad. The puck's position
// blends every parameter between them (bilinear; integer and on/off parameters snap). The puck
// follows the hand, an orbit, or the instrument's tilt.

import 'dart:math' as math;

import 'package:striso_core/striso_core.dart';

const cornerColors = [0xF4D27A, 0xFF8A65, 0x8FDCEC, 0xB9A3FF];
const cornerLetters = ['A', 'B', 'C', 'D'];

enum MorphMode { hand, orbit, tilt }

class Corner {
  final Snapshot snap;
  final String name;
  final int at;
  const Corner(this.snap, this.name, this.at);
  String get voice => snap.voice;

  Map<String, Object?> toJson() => {...snap.toJson(), 'name': name, 'at': at};
  static Corner? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final m = j.cast<String, Object?>();
      return Corner(Snapshot.fromJson(m), (m['name'] as String?) ?? '', (m['at'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }
}

/// The host side: capture the current sound, apply blended values, the current voice, motion.
abstract class MorphHost {
  Snapshot? morphCapture();
  void morphApply(List<double>? weights, List<Snapshot?>? corners, String phase, [String? key]);
  String get morphVoice;
  ({double ax, double ay, double abs, bool fresh}) get morphMotion;
  void morphSave(String voice, Map<String, Object?> state);
}

class MorphModel {
  final MorphHost host;
  List<Corner?> corners = [null, null, null, null];
  double u = 0.5, v = 0.5, tu = 0.5, tv = 0.5;
  MorphMode mode = MorphMode.hand;
  double speed = 0.3, phase = 0;
  final trail = <(double, double)>[];
  bool dragging = false, dirty = true, includeFx = true;
  bool _pendingEnd = false;
  List<double> weights = const [0, 0, 0, 0];

  MorphModel(this.host);

  List<bool> get filled {
    final voice = host.morphVoice;
    return [for (final c in corners) c != null && c.voice == voice];
  }

  bool get ready => filled.where((x) => x).length >= 2;

  String get hint {
    final n = filled.where((x) => x).length;
    return n >= 2
        ? 'Drag the puck to blend the corners.'
        : n == 1
        ? 'Capture one more corner to start morphing.'
        : 'Capture the current sound into two or more corners, change it in between.';
  }

  void load(List<Corner?>? c, [List<double>? pos]) {
    corners = c ?? [null, null, null, null];
    if (pos != null && pos.length == 2) {
      u = tu = pos[0];
      v = tv = pos[1];
    }
    dirty = true;
  }

  void setMode(MorphMode m) {
    mode = m;
    dirty = true;
  }

  void capture(int k) {
    final snap = host.morphCapture();
    if (snap == null) return;
    corners[k] = Corner(snap, snap.label.isNotEmpty ? snap.label : cornerLetters[k], DateTime.now().millisecondsSinceEpoch);
    _save();
    dirty = true;
  }

  void clear(int k) {
    corners[k] = null;
    _save();
    dirty = true;
  }

  void _save() => host.morphSave(host.morphVoice, {
    'corners': [for (final c in corners) c?.toJson()],
    'pos': [u, v],
  });

  // pointer and keys ------------------------------------------------------------------------------

  void dragStart(double pu, double pv) {
    if (!ready) return;
    setMode(MorphMode.hand);
    dragging = true;
    tu = pu.clamp(0, 1);
    tv = pv.clamp(0, 1);
    host.morphApply(null, null, 'begin');
  }

  void dragMove(double pu, double pv) {
    if (!dragging) return;
    tu = pu.clamp(0, 1);
    tv = pv.clamp(0, 1);
  }

  void dragEnd() {
    if (!dragging) return;
    dragging = false;
    _pendingEnd = true;
    _save();
  }

  void nudge(double du, double dv) {
    if (!ready) return;
    setMode(MorphMode.hand);
    tu = (tu + du).clamp(0, 1);
    tv = (tv + dv).clamp(0, 1);
    host.morphApply(null, null, 'begin', 'morph-keys');
    _keyEndAt = _clock.elapsedMilliseconds + 600;
  }

  int _keyEndAt = -1;
  final _clock = Stopwatch()..start();

  void goCorner(int k) {
    if (!filled[k]) return capture(k);
    setMode(MorphMode.hand);
    tu = cornerPos[k].$1;
    tv = cornerPos[k].$2;
    host.morphApply(null, null, 'begin', 'corner-$k');
    _pendingEnd = true;
  }

  /// One animation frame; returns true when the pad should repaint.
  bool frame(double now, double dt) {
    if (_keyEndAt >= 0 && _clock.elapsedMilliseconds >= _keyEndAt) {
      _keyEndAt = -1;
      _pendingEnd = true;
      _save();
    }
    final isReady = ready;
    var moving = false;
    if (isReady && mode == MorphMode.orbit) {
      phase += (dt / 1000) * speed;
      final a = phase * math.pi * 2;
      tu = 0.5 + 0.46 * math.sin(a);
      tv = 0.5 + 0.46 * math.sin(a * 1.5 + 0.7);
    } else if (isReady && mode == MorphMode.tilt) {
      final m = host.morphMotion;
      if (m.fresh) {
        final a = math.max(0.1, m.abs);
        tu = (0.5 + (m.ax / a) * 1.6).clamp(0, 1);
        tv = (0.5 - (m.ay / a) * 1.6).clamp(0, 1);
      }
    }
    final k = 1 - math.exp(-dt / (mode == MorphMode.hand ? 45 : 90));
    final du = tu - u, dv = tv - v;
    if (du.abs() > 1e-4 || dv.abs() > 1e-4) {
      u += du * k;
      v += dv * k;
      moving = true;
    } else if (u != tu || v != tv) {
      u = tu;
      v = tv;
      moving = true;
    }
    if (isReady && moving) {
      final f = filled;
      weights = cornerWeights(u, v, f);
      host.morphApply(weights, [for (var i = 0; i < 4; i++) f[i] ? corners[i]!.snap : null], mode == MorphMode.hand ? 'change' : 'auto');
    }
    if (_pendingEnd && !moving) {
      _pendingEnd = false;
      host.morphApply(null, null, 'end');
    }
    trail.add((u, v));
    if (trail.length > 36) trail.removeAt(0);
    if (!moving && !dirty && !dragging) return false;
    dirty = false;
    return true;
  }
}
