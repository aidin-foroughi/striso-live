// Auditioning a firmware build without flashing it: the real Striso plays a virtual board.
//
// The real board streams its key, control and motion messages (StcS: what its own synth gets,
// saturated to 14 bits on the wire); [AuditionFeed] injects them into the virtual board where the
// virtual board's key scanner would send them, so the candidate firmware's own synth_message
// path runs. The virtual board renders inside the output device's callback (striso_audio's
// sa_set_source with striso_virtual's sv_audio_source): every buffer runs the board for that
// buffer's time first, so a key injected now sounds in the next buffer. [AuditionOutput] attaches
// the source; the app opens the output alone (AudioConfig.outputOnly) through its audio engine.
// The real board's own synth is muted meanwhile (its effects' output level, restored after).
//
// Latency, key to sound: the board's send thread (up to 0.5 ms: one message per 2 kHz tick), the
// USB frame that flushes the bulk IN buffer (up to 1 ms), the host's bulk read and the app's
// event loop (~1 ms), the wait for the next output callback (up to one buffer) and the output
// buffer itself (WASAPI exclusive at 3 ms: about two buffers queued), the virtual board's own block
// (up to 0.67 ms): about 6 to 10 ms on a PC with a 3 ms exclusive output.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:striso_core/striso_core.dart';

import 'board.dart';

typedef _SetSourceN = Void Function(Pointer<Void>, Pointer<Void>);
typedef _SetSource = void Function(Pointer<Void>, Pointer<Void>);
typedef _ConfigureN = Uint32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32);
typedef _Configure = int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int);

/// sa_configure's flags (striso_audio.h)
const saExclusiveOutput = 2, saOutputOnly = 4;

/// striso_audio's output source hook (sa_set_source), on the app's audio engine library.
class AuditionOutput {
  final _SetSource _set;
  final _Configure _configure;
  AuditionOutput._(this._set, this._configure);

  /// null when that library has no sa_set_source (an older striso_audio).
  static AuditionOutput? of(DynamicLibrary audio) {
    try {
      return AuditionOutput._(
        audio.lookupFunction<_SetSourceN, _SetSource>('sa_set_source'),
        audio.lookupFunction<_ConfigureN, _Configure>('sa_configure'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Opens [output] ('' the default) alone with the source attached, [period] frames, exclusive
  /// where the system has it (Windows), or closes it (run false). The engine must be initialised.
  void open({String output = '', int period = 144, bool exclusive = true, bool run = true}) {
    final i = ''.toNativeUtf8(), o = output.toNativeUtf8();
    try {
      _configure(run ? 1 : 0, i, o, period, 0, run ? (saOutputOnly | (exclusive ? saExclusiveOutput : 0)) : 0);
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  /// From now on the output (opened alone) plays [board], rendered in its callback. The board
  /// must not run in real time meanwhile.
  void attach(VirtualBoard board) {
    if (board.realtime) board.stopRealtime();
    _set(board.lib.audioSource, board.handle);
  }

  void detach() => _set(nullptr, nullptr);
}

/// The real board's stream into the virtual board.
class AuditionFeed {
  final VirtualBoard board;
  int keys = 0, controls = 0, motion = 0;
  AuditionFeed(this.board);

  /// A StrisoClient.onStream handler: key (Src.dis), control and stream motion messages.
  void onStream(int src, int id, Int32List v, int n) {
    if (board.disposed || !board.attached) return;
    if (src == Src.dis && n == 4) {
      board.injectKey(id, pres: v[0], velo: v[1], x: v[2], y: v[3]);
      keys++;
    } else if (src == Src.control && n >= 1) {
      board.injectControl(id, v[0]);
      controls++;
    } else if (src == Src.accel && n == 7) {
      // motionsensor.c sends ax/16, ay/16, az/16, |a|, gx/4, gy/4, gz/4 of the sensor's negated axes
      board.injectMotion([
        for (final x in [-v[4] * 4, -v[5] * 4, -v[6] * 4, -v[0] * 16, -v[1] * 16, -v[2] * 16]) x.clamp(-32768, 32767),
      ]);
      motion++;
    }
  }
}

/// The real board's own synth silent (its master effects' output level at its minimum) and back.
class RealBoardMute {
  final StrisoClient client;
  double? _was;
  int? _index;
  RealBoardMute(this.client);

  bool get muted => _was != null;

  Future<bool> mute() async {
    if (muted) return true;
    final fx = await client.getParams(Target.fx);
    final level = fx?.params.where((p) => p.name == 'level').firstOrNull;
    if (level == null) return false;
    _was = level.value;
    _index = level.index;
    client.setParam(Target.fx, level.index, level.min);
    return true;
  }

  Future<void> restore() async {
    final was = _was, i = _index;
    if (was == null || i == null) return;
    _was = null;
    if (client.open) {
      client.setParam(Target.fx, i, was);
      await Future<void>.delayed(const Duration(milliseconds: 40)); // the write goes out
    }
  }
}
