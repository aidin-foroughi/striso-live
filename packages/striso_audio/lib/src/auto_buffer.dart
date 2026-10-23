// Auto buffering for Through PC: start safe, tighten while it plays cleanly, back off one step at
// the first dropout, and remember per output device what worked. Pure logic on a clock; ThroughPc
// feeds it the status every tick and applies the period it asks for.
//
// The steps are the device periods of the native side (64, 128, 256, 512 frames). Every change
// reopens the devices (a short silence), so Auto changes only at a quiet moment of the input
// (except backing off after a dropout, which waits at most a few seconds), and never tightens
// below a size that dropped out on this device, nor below the device's own minimum (a smaller
// request that gives the same device buffer).

import 'dart:math' as math;

/// What Auto learned about one output (in one share mode).
class AutoMemory {
  /// The smallest period that played a while without a dropout.
  final int? stable;

  /// The largest period that dropped out: Auto stays above it (until [failedAt] is old).
  final int? failed;
  final DateTime? failedAt;

  /// The device gives no smaller buffer below this period (its minimum): no point going lower.
  final int? floor;

  const AutoMemory({this.stable, this.failed, this.failedAt, this.floor});

  static const none = AutoMemory();

  AutoMemory copyWith({Object? stable = _keep, Object? failed = _keep, Object? failedAt = _keep, Object? floor = _keep}) => AutoMemory(
    stable: identical(stable, _keep) ? this.stable : stable as int?,
    failed: identical(failed, _keep) ? this.failed : failed as int?,
    failedAt: identical(failedAt, _keep) ? this.failedAt : failedAt as DateTime?,
    floor: identical(floor, _keep) ? this.floor : floor as int?,
  );
  static const _keep = Object();

  Map<String, Object?> toJson() => {
    if (stable != null) 'stable': stable,
    if (failed != null) 'failed': failed,
    if (failedAt != null) 'failedAt': failedAt!.millisecondsSinceEpoch,
    if (floor != null) 'floor': floor,
  };

  static AutoMemory fromJson(Object? j) {
    if (j is! Map) return none;
    int? size(Object? v) => v is num && AutoBuffer.ladder.contains(v.toInt()) ? v.toInt() : null;
    final fa = j['failedAt'];
    return AutoMemory(
      stable: size(j['stable']),
      failed: size(j['failed']),
      failedAt: fa is num ? DateTime.fromMillisecondsSinceEpoch(fa.toInt()) : null,
      floor: size(j['floor']),
    );
  }

  @override
  bool operator ==(Object other) => other is AutoMemory && other.stable == stable && other.failed == failed && other.failedAt == failedAt && other.floor == floor;
  @override
  int get hashCode => Object.hash(stable, failed, failedAt, floor);
  @override
  String toString() => 'AutoMemory(stable $stable, failed $failed, floor $floor)';
}

class AutoTiming {
  /// Clean playing at one size before trying the next smaller one.
  final Duration tighten;

  /// Clean playing before a size is remembered as stable for the device.
  final Duration remember;

  /// Ignored after (re)opening: priming.
  final Duration grace;

  /// The input below this level counts as quiet (a change then is not heard).
  final double quietLevel;
  final Duration quietFor;

  /// Backing off waits for a quiet moment at most this long.
  final Duration backoffWait;

  /// A size that dropped out is tried again after this long.
  final Duration retryFailed;

  const AutoTiming({
    this.tighten = const Duration(seconds: 20),
    this.remember = const Duration(seconds: 60),
    this.grace = const Duration(seconds: 2),
    this.quietLevel = 0.003, // -50 dBFS
    this.quietFor = const Duration(milliseconds: 800),
    this.backoffWait = const Duration(seconds: 3),
    this.retryFailed = const Duration(days: 7),
  });
}

class AutoStep {
  final int period;

  /// The memory changed: save it.
  final AutoMemory? remember;

  /// For the log.
  final String? note;
  const AutoStep(this.period, {this.remember, this.note});
}

class AutoBuffer {
  static const ladder = [64, 128, 256, 512];

  /// Where Auto starts on an output it knows nothing about.
  static const safe = 256;

  final AutoTiming timing;
  AutoBuffer({this.timing = const AutoTiming()});

  String? key;
  int current = safe;

  // the run at the current size
  DateTime? _since;
  int _dropBase = 0;
  bool _graced = false;
  DateTime? _quietSince;

  // a change waiting for a quiet moment
  int? pending;
  bool _pendingBackoff = false;
  DateTime? _pendingAt;

  // the last tightening, to find the device's minimum
  int? _tightenedFrom, _bufferBefore;

  /// Where Auto stands, for the UI: "tightening", "backing off" or "".
  String get phase => pending == null ? '' : (_pendingBackoff ? 'backing off' : 'tightening');

  /// Clean playing at the current size so far.
  Duration cleanFor(DateTime now) => _since == null || !_graced ? Duration.zero : now.difference(_since!);

  static int _up(int p) => ladder[math.min(ladder.length - 1, ladder.indexOf(p) + 1)];

  /// The device's minimum period (frames, 0 unknown): every size below it gives that minimum, so
  /// only the largest of them is worth trying.
  int deviceMin = 0;

  static int floorOf(int deviceMin) {
    if (deviceMin <= ladder.first) return 0;
    return ladder.lastWhere((p) => p <= deviceMin, orElse: () => 0);
  }

  bool _allowed(int size, AutoMemory m, DateTime now) {
    if (m.floor != null && size < m.floor!) return false;
    final df = floorOf(deviceMin);
    if (df > 0 && size < df) return false;
    final f = m.failed;
    if (f == null || size > f) return true;
    return m.failedAt != null && now.difference(m.failedAt!) >= timing.retryFailed;
  }

  int _start(AutoMemory m, DateTime now) {
    var p = m.stable ?? safe;
    if (!ladder.contains(p)) p = safe;
    while (!_allowed(p, m, now) && p < ladder.last) {
      p = _up(p);
    }
    return p;
  }

  void _reset() {
    _since = null;
    _graced = false;
    pending = null;
    _pendingBackoff = false;
    _tightenedFrom = null;
    _bufferBefore = null;
  }

  /// One tick. [key]: the output (and its share mode); [mem]: what is remembered for it;
  /// [playing]: the output plays the input at [current] (the native side applied it);
  /// [dropouts]: the native dropout counter (it restarts with each opening); [level]: the input
  /// peak 0..1; [deviceBuffer]: the output's frames per wake-up as the device took them.
  AutoStep step({
    required DateTime now,
    required String key,
    required AutoMemory mem,
    required bool playing,
    required int dropouts,
    required double level,
    required int deviceBuffer,
    int deviceMin = 0,
  }) {
    this.deviceMin = deviceMin;
    if (key != this.key) {
      this.key = key;
      _reset();
      current = _start(mem, now);
      return AutoStep(current, note: 'auto: $current frames for this output${mem.stable != null ? ' (stable before)' : ''}');
    }
    if (level < timing.quietLevel) {
      _quietSince ??= now;
    } else {
      _quietSince = null;
    }
    final quiet = _quietSince != null && now.difference(_quietSince!) >= timing.quietFor;
    if (!playing) {
      // opening, or a reopen after a change: the run starts again once it plays
      if (pending == null) {
        _since = null;
        _graced = false;
      }
      return AutoStep(current);
    }
    if (_since == null) {
      _since = now;
      _graced = false;
      _dropBase = dropouts;
    }
    if (!_graced) {
      if (now.difference(_since!) < timing.grace) {
        _dropBase = dropouts; // priming
        return AutoStep(current);
      }
      _graced = true;
      _since = now;
      _dropBase = dropouts;
      // a tightening that gave the same device buffer: the device's minimum
      final from = _tightenedFrom, before = _bufferBefore;
      _tightenedFrom = _bufferBefore = null;
      if (from != null && before != null && deviceBuffer > 0 && deviceBuffer >= before) {
        final m = mem.copyWith(floor: from);
        pending = from;
        _pendingBackoff = false;
        _pendingAt = now;
        return AutoStep(current, remember: m, note: 'auto: $current frames gives the same device buffer ($deviceBuffer) as $from: the device minimum');
      }
    }
    if (dropouts < _dropBase) _dropBase = dropouts; // the counter restarted
    if (dropouts > _dropBase) {
      final n = dropouts - _dropBase;
      _dropBase = dropouts;
      _since = now;
      var m = mem.copyWith(failed: math.max(mem.failed ?? 0, current), failedAt: now);
      if (mem.stable != null && mem.stable! <= current) m = m.copyWith(stable: null);
      if (current < ladder.last) {
        pending = _up(current);
        _pendingBackoff = true;
        _pendingAt = now;
        return AutoStep(current, remember: m, note: 'auto: $n dropout${n == 1 ? '' : 's'} at $current frames: backing off to $pending');
      }
      return AutoStep(current, remember: m, note: 'auto: $n dropout${n == 1 ? '' : 's'} at $current frames (the largest)');
    }
    if (pending != null) {
      final waited = now.difference(_pendingAt ?? now);
      if (quiet || (_pendingBackoff && waited >= timing.backoffWait)) {
        final from = current;
        current = pending!;
        final why = _pendingBackoff ? 'backed off' : (current < from ? 'tighter' : 'back');
        pending = null;
        _pendingBackoff = false;
        _since = null;
        _graced = false;
        return AutoStep(current, note: 'auto: $from -> $current frames ($why)');
      }
      return AutoStep(current);
    }
    final clean = now.difference(_since!);
    AutoMemory? remember;
    if (clean >= timing.remember && mem.stable != current) {
      remember = mem.copyWith(stable: current);
    }
    final i = ladder.indexOf(current);
    if (clean >= timing.tighten && i > 0) {
      final lower = ladder[i - 1];
      final m = remember ?? mem;
      if (_allowed(lower, m, now)) {
        pending = lower;
        _pendingBackoff = false;
        _pendingAt = now;
        _tightenedFrom = current;
        _bufferBefore = deviceBuffer;
        return AutoStep(current, remember: remember, note: 'auto: ${clean.inSeconds} s clean at $current frames: trying $lower at the next quiet moment');
      }
    }
    return AutoStep(current, remember: remember, note: remember != null ? 'auto: $current frames stable on this output' : null);
  }
}
