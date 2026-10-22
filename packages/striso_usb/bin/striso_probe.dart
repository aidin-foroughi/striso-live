// Headless check of the libusb path, with no window:
//   dart run striso_usb:striso_probe [--lib path/to/libusb-1.0.dll] probe     enumerate only
//   dart run striso_usb:striso_probe [--lib ...] connect [seconds]            read-only session
// 'connect' does what the app does when it connects (V, v, p, f, S), times each step, counts the
// stream for a moment, then stops the stream and lets go of the board. It sends nothing that
// changes sound, voice or settings.

import 'dart:async';
import 'dart:io';

import 'package:striso_core/striso_core.dart';
import 'package:striso_usb/striso_usb.dart';

Future<void> main(List<String> args) async {
  String? lib;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--lib' && i + 1 < args.length) {
      lib = args[++i];
    } else {
      rest.add(args[i]);
    }
  }
  final mode = rest.isEmpty ? 'probe' : rest.first;
  final seconds = rest.length > 1 ? double.tryParse(rest[1]) ?? 1.0 : 1.0;
  final total = Stopwatch()..start();
  String ms() => '${(total.elapsedMicroseconds / 1000).toStringAsFixed(1).padLeft(7)} ms';

  final service = await UsbService.start(libusbPath: lib);
  service.log.listen((l) => stdout.writeln('${ms()}  libusb: $l'));
  stdout.writeln('${ms()}  worker isolate up');
  try {
    final p = await service.probe();
    stdout.writeln(
      '${ms()}  enumerated in ${(p.took.inMicroseconds / 1000).toStringAsFixed(1)} ms: ${p.present ? 'Striso at ${p.where}' : 'no Striso'}',
    );
    if (mode != 'connect' || !p.present) return;

    final t = service.transport();
    final c = StrisoClient(t);
    c.trace = (s) => stdout.writeln('${ms()}  $s');
    final t0 = total.elapsedMicroseconds;
    double since() => (total.elapsedMicroseconds - t0) / 1000;
    try {
      await c.connect();
    } on UsbError catch (e) {
      stdout.writeln('${ms()}  open failed (${e.code.name}): ${e.message}');
      exitCode = 2;
      return;
    }
    stdout.writeln(
      '${ms()}  claimed interface 2 (open ${(t.openTook.inMicroseconds / 1000).toStringAsFixed(1)} ms in the worker), +${since().toStringAsFixed(0)} ms',
    );
    var keys = 0, motion = 0, other = 0;
    c.onStream = (src, id, v, n) {
      if (src == Src.dis) {
        keys++;
      } else if (src == Src.accel) {
        motion++;
      } else {
        other++;
      }
    };
    final v = await c.getVersion();
    stdout.writeln('${ms()}  version ${v?.fw ?? '(no reply)'}, +${since().toStringAsFixed(0)} ms');
    final voices = await c.listVoices();
    stdout.writeln(
      '${ms()}  ${voices.length} voices, current ${voices.where((x) => x.current).map((x) => x.name).join()}, +${since().toStringAsFixed(0)} ms',
    );
    unawaited(c.startStream());
    stdout.writeln('${ms()}  LIVE (stream on) at +${since().toStringAsFixed(0)} ms after connect');
    final p0 = await c.getParams(0);
    final p1 = await c.getParams(1);
    stdout.writeln('${ms()}  params: ${p0?.params.length ?? 0} voice, ${p1?.params.length ?? 0} fx, +${since().toStringAsFixed(0)} ms');
    await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
    final d = c.diagnostics();
    stdout.writeln('${ms()}  in ${seconds}s: $keys key, $motion motion, $other other messages; ${d.rxBytes} bytes, ${d.parser.truncated} truncated');
    await c.disconnect();
    stdout.writeln('${ms()}  released');
  } finally {
    await service.dispose();
    stdout.writeln('${ms()}  done');
  }
}
