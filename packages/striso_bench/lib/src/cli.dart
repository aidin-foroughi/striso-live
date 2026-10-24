// striso_bench: the Striso's USB audio measured headlessly, one command, a JSON report.
//
//   dart run striso_bench <command> [options]
//
// commands
//   usb-in        the Striso's input, exclusive and shared: latency markers (Stcl1) from the bus to
//                 the app's capture callback, N times (--n, default 50)
//   out           the output alone, playing digital silence, exclusive and shared at 128, 256 and
//                 Auto frames: its latency by its own clock
//   through       Through PC as the app runs it (Auto, the user's exclusive settings), output gain
//                 0 and the silence guard on, --seconds (default 25): end to end, dropouts by
//                 side, where Auto settled, CPU of the audio threads
//   soak          the same for --minutes (default 5), for dropouts
//   targets       board ring targets (--targets 72,80,96) for --seconds each: board underruns
//   stats         the board's StcU, the USB functions and their drivers, the MIDI port
//   all           stats, usb-in, out, through, targets, soak (--minutes; 0 skips the soak)
// options
//   --out-seconds S  how long `out` keeps each configuration open (default 3; 1 with --sim)
//   --excl-in on|off, --excl-out on|off, --period N|auto  override the user's Through PC settings
//   --sim         no hardware: miniaudio's null backend and a simulated board (deterministic)
//   --json FILE   also write the report there (it is always printed to stdout as the last line)
//   --lib PATH    striso_audio library; --libusb PATH  libusb-1.0
//   --keep-app    do not close a running Striso Live (it holds the board's console)
//   --quiet       no progress on stderr
// Exit code: 0 when every check passed, 1 when one failed, 2 when the bench could not run.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:striso_audio/striso_audio.dart';

import 'bench.dart';
import 'console.dart';
import 'report.dart';
import 'sim.dart';
import 'system.dart';
import 'timing.dart';

class Options {
  String command = '';
  bool sim = false, keepApp = false, quiet = false;
  String? json, lib, libusb;
  int n = 50;
  double seconds = 25, minutes = 5;
  double? outSeconds;
  bool? exclIn, exclOut;
  int? period;
  List<int> targets = [72, 80, 96];
}

Options parseArgs(List<String> args) {
  final o = Options();
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() => i + 1 < args.length ? args[++i] : throw FormatException('$a needs a value');
    switch (a) {
      case '--sim':
        o.sim = true;
      case '--keep-app':
        o.keepApp = true;
      case '--quiet':
        o.quiet = true;
      case '--json':
        o.json = next();
      case '--lib':
        o.lib = next();
      case '--libusb':
        o.libusb = next();
      case '--n':
        o.n = int.parse(next());
      case '--seconds':
        o.seconds = double.parse(next());
      case '--out-seconds':
        o.outSeconds = double.parse(next());
      case '--excl-in':
        o.exclIn = next() == 'on';
      case '--excl-out':
        o.exclOut = next() == 'on';
      case '--period':
        final v = next();
        o.period = v == 'auto' ? 0 : int.parse(v);
      case '--minutes':
        o.minutes = double.parse(next());
      case '--targets':
        o.targets = next().split(',').map(int.parse).toList();
      default:
        if (a.startsWith('--')) throw FormatException('unknown option $a');
        if (o.command.isNotEmpty) throw FormatException('one command at a time ($a)');
        o.command = a;
    }
  }
  const commands = ['usb-in', 'out', 'through', 'soak', 'targets', 'stats', 'all'];
  if (!commands.contains(o.command)) throw FormatException('command: ${commands.join(' | ')}');
  return o;
}

/// The repository root (bin/ is packages/striso_bench/bin).
String _root() {
  final s = Platform.script.toFilePath();
  var d = File(s).parent;
  for (var i = 0; i < 6; i++) {
    if (File('${d.path}${Platform.pathSeparator}pubspec.yaml').existsSync() && Directory('${d.path}${Platform.pathSeparator}packages').existsSync()) return d.path;
    d = d.parent;
  }
  return Directory.current.path;
}

String? _firstExisting(List<String> c) => c.where((p) => File(p).existsSync()).firstOrNull;

String? defaultAudioLib() {
  final r = _root();
  return _firstExisting([
    if (Platform.isWindows) ...['$r\\build\\striso_audio\\Release\\striso_audio.dll', '$r\\build\\windows\\x64\\runner\\Release\\striso_audio.dll'],
    if (Platform.isMacOS) '$r/packages/striso_audio/native/build/macos/libstriso_audio.dylib',
  ]);
}

String? defaultLibusb() {
  final r = _root();
  return _firstExisting([
    if (Platform.isWindows) '$r\\windows\\libusb\\libusb-1.0.dll',
    if (Platform.isMacOS) ...['/opt/homebrew/lib/libusb-1.0.0.dylib', '/usr/local/lib/libusb-1.0.0.dylib'],
  ]);
}

/// The user's audio settings from Striso Live's settings.json, read only.
AudioPrefs userPrefs() {
  final env = Platform.environment;
  final home = env['STRISO_LIVE_HOME'] ??
      (Platform.isWindows ? '${env['APPDATA']}\\Striso Live' : Platform.isMacOS ? '${env['HOME']}/Library/Application Support/Striso Live' : '${env['HOME']}/.config/striso-live');
  try {
    final j = jsonDecode(File('$home${Platform.pathSeparator}settings.json').readAsStringSync());
    if (j is Map) return AudioPrefs.fromJson(j['audio']);
  } catch (_) {}
  return const AudioPrefs();
}

/// Windows: Striso Live holds the board's console; it is closed (the user asked not to be asked).
Future<bool> closeStrisoLive() async {
  if (!Platform.isWindows) {
    final r = await Process.run('pkill', ['-x', 'Striso Live']);
    return r.exitCode == 0;
  }
  final r = await Process.run('taskkill', ['/IM', 'StrisoLive.exe', '/F']);
  if (r.exitCode == 0) await Future<void>.delayed(const Duration(seconds: 2));
  return r.exitCode == 0;
}

Future<int> runCli(List<String> args) async {
  final Options o;
  try {
    o = parseArgs(args);
  } on FormatException catch (e) {
    stderr.writeln('striso_bench: ${e.message}\n(see the header of packages/striso_bench/lib/src/cli.dart)');
    return 2;
  }
  void log(String s) {
    if (!o.quiet) stderr.writeln(s);
  }

  final started = DateTime.now();
  final sw = Stopwatch()..start();
  final notes = <String>[];
  final audio = NativeAudioBackend.tryLoad(explicit: o.lib ?? defaultAudioLib(), backend: o.sim ? backendNull : backendSystem);
  if (audio == null) {
    stderr.writeln('striso_bench: ${NativeAudioBackend.loadError}\nbuild it: cmake -S packages/striso_audio/native -B build/striso_audio && cmake --build build/striso_audio --config Release');
    return 2;
  }
  // the null backend has no Striso: its input stands in
  final prefs = o.sim ? const AudioPrefs(input: 'NULL Capture Device', exclusive: false, exclusiveOutput: false) : userPrefs();
  var prefs1 = prefs;
  if (o.exclIn != null) prefs1 = prefs1.copyWith(exclusive: o.exclIn);
  if (o.exclOut != null) prefs1 = prefs1.copyWith(exclusiveOutput: o.exclOut);
  if (o.period != null) prefs1 = prefs1.copyWith(period: o.period);
  BoardConsole? board;
  String? version;
  final needsBoard = o.command != 'out';
  if (o.sim) {
    board = SimConsole(audio.clockUs);
  } else if (needsBoard) {
    if (!o.keepApp && await closeStrisoLive()) notes.add('closed Striso Live (it held the board\'s console)');
    final off = clockOffset(() => Timeline.now, audio.clockUs);
    log('clock offset (audio - Dart) ${off.offsetUs} us +-${off.uncertaintyUs}');
    board = await UsbConsole.open(clockOffsetUs: off.offsetUs, libusb: o.libusb ?? defaultLibusb(), log: log);
    if (board == null) notes.add('no board console: the Striso is not connected, or another program holds it');
  }
  if (board != null) version = await board.version();
  final env = BenchEnv(audio: audio, board: board, sim: o.sim, prefs: prefs1, log: log);
  final overridden = o.exclIn != null || o.exclOut != null || o.period != null;
  final from = o.sim ? '' : (overridden ? ' (settings.json, overridden on the command line)' : ' (settings.json)');
  notes.add('Through PC settings: input ${prefs1.exclusive ? 'exclusive' : 'shared'}, output ${prefs1.exclusiveOutput ? 'exclusive' : 'shared'}, '
      'buffer ${prefs1.isAuto ? 'Auto' : prefs1.period}$from');
  final results = <String, Object?>{};
  var touchedTarget = false;

  Future<void> step(String name, Future<Map<String, Object?>> Function() f) async {
    log('-- $name');
    try {
      results[name] = await f();
    } catch (e, st) {
      results[name] = {'error': '$e'};
      notes.add('$name failed: $e');
      log('$name: $e\n$st');
    }
  }

  final cmd = o.command;
  final all = cmd == 'all';
  if (cmd == 'stats' || all) {
    await step('stats', () async {
      final s = await board?.usbStats();
      final pnp = await strisoPnp();
      final midi = midiInputs();
      if (!audio.init()) return {'error': 'the audio system did not start'};
      final g = audio.status().devicesGen;
      audio.requestDevices();
      final t = Stopwatch()..start();
      while (audio.status().devicesGen == g && t.elapsedMilliseconds < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final ins = audio.devices(capture: true);
      final striso = pickInput(ins, null);
      audio.shutdown();
      return {
        'board': s == null ? {'available': false} : {'lines': s.lines, 'underruns': s.underruns, 'host_skipped': s.hostSkipped, 'ring_target': s.ringTarget, 'streaming': s.streaming, 'uac': s.uac},
        'firmware': version,
        'pnp': pnp,
        'audio_driver': o.sim ? 'usbaudio2' : audioDriverOf(pnp),
        'console_driver': o.sim ? 'WINUSB' : consoleDriverOf(pnp),
        'midi_inputs': midi,
        'midi_port': o.sim ? 'Striso' : midi.where((m) => m.toLowerCase().contains('striso')).firstOrNull,
        'audio_input': o.sim ? 'sim' : striso?.name,
        'audio_input_by_usb_ids': striso?.isStriso,
      };
    });
  }
  if (cmd == 'usb-in' || all) {
    for (final excl in [true, false]) {
      if (!excl && !Platform.isWindows && !o.sim) continue;
      await step('usb_in_${excl ? 'exclusive' : 'shared'}', () async => o.sim ? simUsbIn(n: o.n, exclusive: excl) : runUsbIn(env, exclusive: excl, n: o.n));
    }
  }
  if (cmd == 'out' || all) await step('out', () => runOut(env, seconds: o.outSeconds ?? (o.sim ? 1 : 3)));
  if (cmd == 'through' || all) await step('through', () => runThrough(env, seconds: o.seconds));
  if (cmd == 'targets' || all) {
    touchedTarget = true;
    await step('targets', () => runThrough(env, seconds: all ? 20 : o.seconds, boardTargets: o.targets, markerEvery: 0, label: 'targets'));
  }
  if ((cmd == 'soak' || all) && o.minutes > 0) {
    await step('soak', () => runThrough(env, seconds: o.minutes * 60, markerEvery: 10, label: 'soak'));
  }
  if (cmd == 'through' || cmd == 'soak') touchedTarget = true;
  if (board != null) {
    if (touchedTarget || all) {
      final t = await board.setTarget(96);
      notes.add('board ring target left at ${t ?? '?'} frames (the default 96)');
    }
    await board.close();
  }
  final checks = checksOf(results, sim: o.sim);
  final report = <String, Object?>{
    'schema': schemaId,
    'command': cmd,
    'started': started.toIso8601String(),
    'duration_s': sw.elapsedMilliseconds / 1000,
    'host': {
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'dart': Platform.version.split(' ').first,
      'audio': audio.description,
      'sim': o.sim,
      'hostname': Platform.localHostname,
    },
    'board': board == null ? null : {'console': board.label, 'version': version},
    'results': results,
    'checks': [for (final c in checks) c.toJson()],
    'ok': checks.every((c) => c.ok) && !results.values.any((v) => v is Map && v.containsKey('error')),
    'notes': notes,
  };
  final problems = validateReport(report);
  if (problems.isNotEmpty) {
    (report['notes'] as List).add('report schema problems: ${problems.join('; ')}');
    report['ok'] = false;
  }
  final text = const JsonEncoder.withIndent('  ').convert(report);
  if (o.json != null) {
    File(o.json!)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  for (final c in checks) {
    log('${c.ok ? 'ok  ' : 'FAIL'}  ${c.name}: ${c.value} (${c.limit})');
  }
  stdout.writeln(jsonEncode(report));
  return report['ok'] == true ? 0 : 1;
}
