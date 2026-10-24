// The hardware suite: `dart test -t hardware` (tools/hwtest.ps1, tools/hwtest.sh run it after the
// bench). Skipped unless a Striso is on USB. Each test reads the bench's report: the one in
// STRISO_BENCH_REPORT (the suite's own run), else it runs the bench command itself. They close a
// running Striso Live (it holds the board's console). Nothing plays a sound.
@Tags(['hardware'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:striso_bench/striso_bench.dart';
import 'package:test/test.dart';

String _libusb() {
  final p = Platform.isWindows ? '../../windows/libusb/libusb-1.0.dll' : '/opt/homebrew/lib/libusb-1.0.0.dylib';
  return File(p).existsSync() ? File(p).absolute.path : '';
}

Future<String> _probe(List<String> args) async {
  final lib = _libusb();
  final r = await Process.run('dart', ['run', 'striso_usb:striso_probe', if (lib.isNotEmpty) ...['--lib', lib], ...args], workingDirectory: '../striso_usb');
  return '${r.stdout}${r.stderr}';
}

Map<String, Object?>? _shared;

Future<Map<String, Object?>> _report(String command, List<String> extra) async {
  final env = Platform.environment['STRISO_BENCH_REPORT'];
  if (env != null && File(env).existsSync()) return _shared ??= jsonDecode(File(env).readAsStringSync()) as Map<String, Object?>;
  final r = await Process.run('dart', ['run', 'bin/striso_bench.dart', command, '--quiet', ...extra]);
  final last = (r.stdout as String).trim().split('\n').last;
  return jsonDecode(last) as Map<String, Object?>;
}

void main() async {
  final present = (await _probe(['probe'])).contains('Striso at');
  final skip = present ? null : 'no Striso on USB';

  test('connect is live in under 1 s (striso_probe)', () async {
    if (Platform.isWindows) await Process.run('taskkill', ['/IM', 'StrisoLive.exe', '/F']);
    final out = await _probe(['connect', '0.3']);
    final m = RegExp(r'LIVE \(stream on\) at \+(\d+) ms after connect').firstMatch(out);
    expect(m, isNotNull, reason: out);
    expect(int.parse(m!.group(1)!), lessThan(1000));
  }, skip: skip);

  test('stats: usbaudio2 bound to the audio function, the MIDI port and the input are there', () async {
    final r = await _report('stats', []);
    expect(validateReport(r), isEmpty);
    expect(at(r, 'results.stats.audio_input'), isNotNull);
    if (Platform.isWindows) {
      expect(at(r, 'results.stats.audio_driver'), 'usbaudio2');
      expect(at(r, 'results.stats.midi_port'), isNotNull);
    }
  }, skip: skip);

  test('usb-in: median latency under 8 ms (exclusive), markers found', () async {
    final r = await _report('usb-in', ['--n', '30']);
    expect(validateReport(r), isEmpty);
    final med = at(r, 'results.usb_in_exclusive.usb_in_ms.median') ?? at(r, 'results.usb_in_shared.usb_in_ms.median');
    expect(med, isA<num>());
    expect(med as num, lessThan(8));
    final k = at(r, 'results.usb_in_exclusive') != null ? 'usb_in_exclusive' : 'usb_in_shared';
    expect(at(r, 'results.$k.markers.found') as num, greaterThanOrEqualTo((at(r, 'results.$k.markers.sent') as num) * 0.9));
  }, skip: skip);

  test('through: silent output, no board underruns over the run', () async {
    final r = await _report('through', ['--seconds', '30']);
    expect(validateReport(r), isEmpty);
    expect(at(r, 'results.through.silence_violations'), 0);
    expect(at(r, 'results.through.gain'), 0);
    expect(at(r, 'results.through.board_underruns'), 0);
  }, skip: skip);
}
