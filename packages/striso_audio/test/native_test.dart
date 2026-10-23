// The native library itself, when it has been built: its self-test (passthrough math, drift
// servo, resampler, WAV writer, a null-backend session) and the dart:ffi binding through a
// session on miniaudio's null backend. Opens no real audio device. Skips without a build:
//   cmake -S native -B ../../build/striso_audio && cmake --build ../../build/striso_audio --config Release
// (Windows; macOS: sh native/build_macos.sh), or STRISO_AUDIO_LIB=<path to the library>.
import 'dart:io';

import 'package:striso_audio/striso_audio.dart';
import 'package:test/test.dart';

String? findLib() {
  final env = Platform.environment['STRISO_AUDIO_LIB'];
  final c = [
    if (env != null && env.isNotEmpty) env,
    if (Platform.isWindows) ...[
      '../../build/striso_audio/Release/striso_audio.dll',
      '../../build/windows/x64/runner/Release/striso_audio.dll',
    ],
    if (Platform.isMacOS) 'native/build/macos/libstriso_audio.dylib',
    if (Platform.isLinux) '../../build/striso_audio/libstriso_audio.so',
  ];
  for (final p in c) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

void main() {
  final lib = findLib();
  final skip = lib == null ? 'striso_audio is not built (see the header of this file)' : null;

  test('native self-test passes', () {
    final l = StrisoAudioLib.load(explicit: lib);
    final dir = Directory.systemTemp.createTempSync('striso_audio_selftest');
    final (fails, report) = l.runSelftest(dir.path);
    printOnFailure(report);
    // ignore: avoid_print
    print(report);
    dir.deleteSync(recursive: true);
    expect(fails, 0);
  }, skip: skip);

  test('dart:ffi binding: a session on the null backend', () async {
    final b = NativeAudioBackend.tryLoad(explicit: lib, backend: backendNull)!;
    expect(b.init(), isTrue);
    Future<AudioStatus> until(bool Function(AudioStatus) ok) async {
      for (var i = 0; i < 400; i++) {
        final s = b.status();
        if (ok(s)) return s;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return b.status();
    }

    final g0 = b.status().devicesGen;
    b.requestDevices();
    await until((s) => s.devicesGen != g0);
    final ins = b.devices(capture: true), outs = b.devices(capture: false);
    expect(ins.map((d) => d.name), contains('NULL Capture Device'));
    expect(outs.map((d) => d.name), contains('NULL Playback Device'));
    b.setGain(0.25);
    final gen = b.configure(const AudioConfig(run: true, input: 'NULL Capture Device', period: 256, monitor: true));
    var s = await until((s) => s.configGen >= gen && s.capture == DevState.running && s.playback == DevState.running);
    expect(s.capture, DevState.running);
    expect(s.captureRate, 48000);
    expect(s.gain, 0.25);
    s = await until((s) => s.streaming);
    expect(s.streaming, isTrue);
    expect(s.latencyMs, greaterThan(0));

    final dir = Directory.systemTemp.createTempSync('striso_audio_ffi');
    final path = '${dir.path}${Platform.pathSeparator}take ü.wav';
    b.recordStart(path);
    await until((s) => s.record == RecState.on);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    b.recordStop();
    s = await until((s) => s.record != RecState.on);
    expect(s.record, RecState.idle);
    expect(s.recordFrames, greaterThan(4800));
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: 'UTF-8 file names');
    final bytes = f.readAsBytesSync();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

    final g2 = b.configure(AudioConfig.off);
    s = await until((s) => s.configGen >= g2);
    expect(s.capture, DevState.closed);
    expect(b.documentsDir(), isNotNull);
    b.shutdown();
    dir.deleteSync(recursive: true);
  }, skip: skip);
}
