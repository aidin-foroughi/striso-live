// The board's side of Through PC: while it plays, the board's own USB audio counters every 2 s
// (console StcU; they reset on every call), so a dropout can be told apart (on the board, in the
// computer's input, in its output), and the board's ring target (Stct) as ThroughPc wants it
// (Auto or the chosen one). The first reply after starting only sets the baseline (it counts since
// whenever U was last asked). Firmware that does not answer is not asked again in this session.
//
// Shared by the app (AppController, over its StrisoClient) and the bench (packages/striso_bench,
// over its console), so both run the same policy.

import 'dart:async';

import 'package:striso_core/striso_core.dart' show UsbAudioStats;

import 'through_pc.dart';

/// The board's counters as ThroughPc takes them.
BoardAudioStats boardAudioStatsOf(UsbAudioStats s) => BoardAudioStats(
  sent: s.sent,
  missed: s.missed,
  underruns: s.underruns,
  overruns: s.overruns,
  primes: s.primes,
  ringFiltered: s.ringFiltered?.toDouble(),
  ringMin: s.ringMin,
  ringMax: s.ringMax,
  ringTarget: s.ringTarget,
  streaming: s.streaming,
  hostSkipped: s.hostSkipped,
  notReady: s.notReady,
  uac: s.uac,
);

class BoardAudioLink {
  final ThroughPc audio;

  /// StcU: the counters since the last call, or null (no reply).
  final Future<UsbAudioStats?> Function() getStats;

  /// Stct: sets the ring target; the target the board reports, or null (no Stct).
  final Future<int?> Function(int frames) setTarget;

  /// Still the same connection (false ends the loop).
  final bool Function() alive;

  /// Skip this round (connecting, saving to the board).
  final bool Function() paused;
  final void Function(String) log;

  /// Called after the board took a new target.
  final void Function()? onTarget;
  final Duration every;

  /// The board's ring target as last set (it forgets it at a restart: a new link).
  int? targetSet;

  /// Every reply, after the baseline (the bench keeps them).
  final void Function(UsbAudioStats)? onStats;

  BoardAudioLink({
    required this.audio,
    required this.getStats,
    required this.setTarget,
    required this.alive,
    bool Function()? paused,
    required this.log,
    this.onTarget,
    this.onStats,
    this.every = const Duration(seconds: 2),
  }) : paused = paused ?? (() => false);

  Future<void> _setTarget() async {
    final want = audio.boardTargetWanted;
    if (audio.boardTargetSupported == false || want == targetSet) return;
    final v = await setTarget(want);
    if (!alive()) return;
    if (v == null) {
      audio.boardTargetSupported = false;
      log('the board does not take a USB audio ring target (Stct): its own stays');
    } else {
      audio.boardTargetSupported = true;
      targetSet = v;
      log('board USB audio ring target: $v frames (${(v / 48).toStringAsFixed(2)} ms)');
      onTarget?.call();
    }
  }

  /// Runs until [alive] says no or the board stops answering (3 misses).
  Future<void> run() async {
    var misses = 0;
    var baseline = true;
    while (alive() && misses < 3) {
      await Future<void>.delayed(every);
      if (!alive() || paused()) continue;
      if (!audio.playing) {
        baseline = true;
        continue;
      }
      final s = await getStats();
      if (!alive()) return;
      if (s == null) {
        misses++;
        if (misses == 3) log('the board does not report its USB audio counters (StcU): board-side dropouts are not counted');
        continue;
      }
      misses = 0;
      if (baseline) {
        baseline = false;
        if (s.uac != null) log('board USB audio: UAC${s.uac}, ring target ${s.ringTarget ?? '?'} frames');
        if (s.drops > 0) log('board USB audio before this: ${s.underruns ?? 0} underruns, ${s.hostSkipped ?? 0} host-skipped frames (not counted)');
        await _setTarget();
        continue;
      }
      onStats?.call(s);
      audio.boardStats(boardAudioStatsOf(s));
      await _setTarget();
    }
  }
}
