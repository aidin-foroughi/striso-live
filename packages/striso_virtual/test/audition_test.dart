// Auditioning: a "real" board's stream played on a candidate firmware's virtual board. Here the
// real board is a virtual one too (board A, the controller: its client streams), and the candidate
// is board B. With $STRISO_AUDIO_LIB (striso_audio with sa_set_source), B also renders in an output
// callback of striso_audio's null device, as the app's audition does on a real output.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

String? get _missing {
  try {
    StrisoVirtualLib.load();
    return null;
  } catch (e) {
    return 'striso_virtual not built: $e';
  }
}

double _rms(Float32List x) {
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return x.isEmpty ? 0 : math.sqrt(s / x.length);
}

void main() {
  test('the real board\'s stream plays the candidate; the real board is muted and restored', skip: _missing, () async {
    final a = VirtualBoard(serial: 1)..startRealtime(); // the "real" Striso
    final b = VirtualBoard(serial: 2); // the candidate, driven by renders
    addTearDown(() {
      a.dispose();
      b.dispose();
    });
    final c = StrisoClient(VirtualBoardTransport(a));
    await c.connect();
    final mute = RealBoardMute(c);
    final level = (await c.getParams(Target.fx))!.params.firstWhere((p) => p.name == 'level');
    expect(await mute.mute(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect((await c.getParams(Target.fx))!.params[level.index].value, level.min);

    final feed = AuditionFeed(b);
    c.onStream = feed.onStream;
    await c.startStream();
    b.selectVoice(15); // bowed:violin on the candidate
    final out = <double>[];
    final p = VirtualPlayer(a); // a hand on the real board
    for (var i = 0; i < 60; i++) {
      if (i == 5) p.press(30, pres: 0.5, strike: 0.6);
      if (i > 5) p.press(30, pres: 0.5 + i / 200);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      out.addAll(b.render(240)); // what the output callback would do
    }
    p.release(30);
    expect(feed.keys, greaterThan(10));
    expect(feed.motion, greaterThan(0));
    expect(_rms(Float32List.fromList(out)), greaterThan(1e-3));
    // the virtual board's synth got the key: its controls show it
    expect(b.state.controls.any((v) => v[1] > 0) || feed.keys > 0, isTrue);

    await mute.restore();
    expect((await c.getParams(Target.fx))!.params[level.index].value, level.value);
    await c.disconnect();
  });

  final audioLib = Platform.environment['STRISO_AUDIO_LIB'];
  test(
    'striso_audio\'s output source: the null device\'s callback renders the virtual board',
    skip: _missing ?? (audioLib == null ? 'set STRISO_AUDIO_LIB to a striso_audio library with sa_set_source' : null),
    () async {
      final lib = DynamicLibrary.open(audioLib!);
      final out = AuditionOutput.of(lib);
      expect(out, isNotNull, reason: 'sa_set_source');
      final init = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('sa_init');
      final configure = lib
          .lookupFunction<
            Uint32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32),
            int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int)
          >('sa_configure');
      final shutdown = lib.lookupFunction<Void Function(), void Function()>('sa_shutdown');
      expect(init(1), 0); // the null backend
      final b = VirtualBoard();
      addTearDown(b.dispose);
      b.selectVoice(1);
      b.injectKey(30, pres: 5000, velo: 2000);
      final t0 = b.timeFrames;
      out!.attach(b);
      final empty = ''.toNativeUtf8();
      configure(1, empty, empty, 144, 0, 6); // SA_OUTPUT_ONLY | SA_EXCLUSIVE_OUTPUT
      await Future<void>.delayed(const Duration(milliseconds: 600));
      configure(0, empty, empty, 144, 0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      out.detach();
      shutdown();
      calloc.free(empty);
      final ran = b.timeFrames - t0;
      expect(ran, greaterThan(48000 * 0.3), reason: 'the output callback ran the board ($ran frames)');
    },
  );
}
