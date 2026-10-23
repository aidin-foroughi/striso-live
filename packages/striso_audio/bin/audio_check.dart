// Headless check of the audio engine on this computer, through the same Dart code as the app
// (ThroughPc over dart:ffi). Never plays a sound: it opens no output device.
//
//   dart run bin/audio_check.dart [--lib PATH] list
//   dart run bin/audio_check.dart [--lib PATH] record SECONDS [DIR]
//       records the Striso's input (Through PC off: the input only) for at most 5 s into DIR
//       (default: the system temp folder) and reports the format, the level and the file
//
// The library: --lib, STRISO_AUDIO_LIB, or the usual places (striso_audio.dll next to the app).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:striso_audio/striso_audio.dart';

Future<void> main(List<String> args) async {
  var a = List.of(args);
  String? lib;
  final i = a.indexOf('--lib');
  if (i >= 0 && i + 1 < a.length) {
    lib = a[i + 1];
    a.removeRange(i, i + 2);
  }
  final b = NativeAudioBackend.tryLoad(explicit: lib);
  if (b == null) {
    stderr.writeln(NativeAudioBackend.loadError);
    exit(2);
  }
  stdout.writeln(b.description);
  if (a.isEmpty || a.first == 'list') {
    if (!b.init()) {
      stderr.writeln('the audio system did not start');
      exit(1);
    }
    final g = b.status().devicesGen;
    b.requestDevices();
    for (var n = 0; n < 300 && b.status().devicesGen == g; n++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final ins = b.devices(capture: true);
    for (final d in ins) {
      stdout.writeln('input   ${d.name}${d.isDefault ? '  [default]' : ''}${d.isStriso ? '  [Striso by USB VID/PID]' : ''}'
          '${d.nativeBits != 0 ? '  ${ThroughPc.bitsText(d.nativeBits)} ${d.nativeRate} Hz' : ''}');
    }
    for (final d in b.devices(capture: false)) {
      stdout.writeln('output  ${d.name}${d.isDefault ? '  [default]' : ''}');
    }
    stdout.writeln('the Striso: ${pickInput(ins, null)?.name ?? 'not found'}');
    b.shutdown();
    return;
  }
  if (a.first != 'record' || a.length < 2) {
    stderr.writeln('usage: audio_check.dart [--lib PATH] list | record SECONDS [DIR]');
    exit(64);
  }
  final secs = math.min(5.0, double.tryParse(a[1]) ?? 3);
  final dir = a.length > 2 ? a[2] : Directory.systemTemp.path;
  final pc = ThroughPc(
    backend: b,
    prefs: const AudioPrefs(through: false), // the input only: no output device
    log: (s) => stdout.writeln('  $s'),
    recordingsDir: () => dir,
  );
  pc.start();
  pc.startRecording();
  var peak = 0.0;
  final sw = Stopwatch()..start();
  while (!pc.recording && sw.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!pc.recording) {
    stdout.writeln('did not start: ${pc.message}${pc.recordNote != null ? ' / ${pc.recordNote}' : ''}');
    pc.dispose();
    exit(1);
  }
  for (var n = 0; n < 40 && pc.st.record != RecState.on; n++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  final st0 = pc.st;
  stdout.writeln('input: ${st0.captureRate} Hz, ${ThroughPc.bitsText(st0.captureBits)}, ${st0.captureExclusive ? 'exclusive' : 'shared'}, '
      'period ${st0.capturePeriod} frames; recording ${ThroughPc.bitsText(st0.recordBits)}');
  sw.reset();
  while (sw.elapsedMilliseconds < secs * 1000) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    peak = math.max(peak, pc.level);
  }
  pc.stopRecording();
  while (pc.recording && sw.elapsedMilliseconds < secs * 1000 + 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final st = pc.st;
  final path = pc.lastRecording;
  stdout.writeln('recorded ${st.recordFrames} frames (${(st.recordFrames / 48000).toStringAsFixed(2)} s), ${st.recordDropped} dropped, '
      'meter peak ${peak > 0 ? '${(20 * math.log(peak) / math.ln10).toStringAsFixed(1)} dBFS' : 'silence'}');
  stdout.writeln('file: ${path ?? '(none)'}${path != null ? ', ${File(path).lengthSync()} bytes' : ''}');
  if (pc.recordNote != null) stdout.writeln('note: ${pc.recordNote}');
  pc.dispose();
  exit(path != null ? 0 : 1);
}
