// The measurements. Each runs the app's own audio engine (striso_audio through dart:ffi) and its
// Through PC state machine (ThroughPc, BoardAudioLink), with the probe on: the native callbacks'
// timing marks and taps, plus the board's console (the latency marker). Nothing here makes a
// sound: every real output is opened only to play digital silence, the native silence guard
// forces every output sample to 0 and counts any that was not, and a run fails if one was.
//
// Every number in a result says how it was obtained:
//   measured   from clocks and the audio itself (the marker, the devices' own timestamps)
//   reported   what a device or the board says about itself (a stream latency, a ring level)
//   estimated  a model where nothing better is available (named in the result)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart' show UsbAudioStats;

import 'console.dart';
import 'marker.dart';
import 'stats.dart';
import 'timing.dart';

/// A real output stays open at most this long per run (the brief: 30 s of silence).
const maxOutputSeconds = 30;

class BenchEnv {
  final NativeAudioBackend audio;
  final BoardConsole? board;

  /// The null backend and a simulated board: deterministic, no hardware.
  final bool sim;

  /// The user's audio settings (read only: never written back).
  final AudioPrefs prefs;
  final void Function(String) log;
  BenchEnv({required this.audio, this.board, this.sim = false, this.prefs = const AudioPrefs(), required this.log});

  int clock() => audio.clockUs();
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

double _ms(num us) => us / 1000.0;
double _r3(double x) => (x * 1000).roundToDouble() / 1000;
Object? _st(Iterable<num> v) => Stats.of(v)?.toJson();

/// The board's buffer before a packet as the app reckons it (through_pc.dart, Breakdown): a
/// sample waits about its level less half a packet, then the packet is armed for the next frame
/// (1 ms) and crosses the bus (0.23 ms). Reported (the level is the board's own).
double boardPartMs(num level) => math.max(0.0, level - 24) / 48 + 1.23;

/// One channel of a tap, in chunks, by device frame (trimmed as a long run goes on).
class TapStore {
  final _chunks = <(int, Float32List)>[];
  int? get first => _chunks.isEmpty ? null : _chunks.first.$1;
  int get end => _chunks.isEmpty ? 0 : _chunks.last.$1 + _chunks.last.$2.length;
  void clear() => _chunks.clear();
  void add(int frame, Float32List x) => _chunks.add((frame, x));

  /// Frames [from, to) (zeros where nothing is kept).
  Float32List slice(int from, int to) {
    final out = Float32List(math.max(0, to - from));
    for (final (f, x) in _chunks) {
      final lo = math.max(from, f), hi = math.min(to, f + x.length);
      for (var i = lo; i < hi; i++) {
        out[i - from] = x[i - f];
      }
    }
    return out;
  }

  void trimBefore(int frame) => _chunks.removeWhere((c) => c.$1 + c.$2.length < frame);
}

/// Collects the probe's taps and marks while a run goes on (every 20 ms).
class ProbeCollector {
  final NativeAudioBackend audio;
  final CaptureTimeline cap;
  final PlayTimeline play;

  /// The right channel (the marker's) of each tap: input [0], output before its gain [1].
  final taps = [TapStore(), TapStore()];
  final tapSession = [-1, -1];
  Timer? _timer;

  ProbeCollector(this.audio, {double inRate = 48000, double outRate = 48000}) : cap = CaptureTimeline(inRate), play = PlayTimeline(outRate);

  void start() {
    audio.probe(true);
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => drain());
  }

  void drain() {
    final marks = audio.probeMarks();
    cap.add(marks);
    play.add(marks);
    for (var k = 0; k < 2; k++) {
      final a = audio.probeAudio(k);
      if (a == null) continue;
      if (a.session != tapSession[k]) {
        tapSession[k] = a.session;
        taps[k].clear();
      }
      taps[k].add(a.firstFrame, channelOf(a.samples, 1));
    }
  }

  void stop() {
    _timer?.cancel();
    drain();
    audio.probe(false);
  }

  /// The marker in tap [k] between device frames [from] and [to].
  ({double frame, MarkerHit hit})? find(int k, int from, int to) {
    final x = taps[k].slice(from, to);
    final h = findMarker(x);
    return h == null ? null : (frame: from + h.at, hit: h);
  }
}

/// The console's one-way time (us): half of each echo's round trip less what the board held it.
Future<({double owdUs, List<double> rttMs, List<double> transitMs})> consoleLatency(BoardConsole b, {int n = 20}) async {
  final rtt = <double>[], transit = <double>[];
  for (var i = 0; i < n; i++) {
    final e = await b.echo();
    if (e.reply != null) {
      rtt.add(_ms(e.rttUs));
      transit.add(_ms(e.rttUs - e.reply!));
    }
    await _sleep(7);
  }
  return (owdUs: transit.isEmpty ? double.nan : median(transit) * 1000 / 2, rttMs: rtt, transitMs: transit);
}

Future<bool> _until(bool Function() ok, {int ms = 8000}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsedMilliseconds > ms) return false;
    await _sleep(20);
  }
  return true;
}

Map<String, Object?> _captureInfo(AudioStatus s) => {
  'exclusive': s.captureExclusive,
  'bits': s.captureBits,
  'rate': s.captureRate,
  'buffer_frames': s.captureBuffer,
  'device_min_frames': s.captureDevMin,
  'stream_latency_frames_reported': s.captureStreamLatency,
};

Map<String, Object?> _boardStatsJson(UsbAudioStats? s) => s == null
    ? {'available': false}
    : {
        'available': true,
        'uac': s.uac,
        'streaming': s.streaming,
        'sent': s.sent,
        'missed': s.missed,
        'host_skipped': s.hostSkipped,
        'underruns': s.underruns,
        'overruns': s.overruns,
        'not_ready': s.notReady,
        'ring_target': s.ringTarget,
        'ring_filtered': s.ringFiltered,
        'ring_min': s.ringMin,
        'ring_max': s.ringMax,
        'rate_hz': s.rateHz,
        'sof_late': s.sofLate,
        'blocks_lost': s.blocksLost,
        'cpu_percent': s.cpuPercent,
      };

// ------------------------------------------------------------------------------------- usb-in

/// One marker: everything measured about it.
class UsbInTrial {
  final int sentUs, writtenUs, replyUs;
  final MarkerReply reply;
  final double? frame, score;
  final double? cbUs, devUs;
  final double owdUs;
  UsbInTrial(this.sentUs, this.writtenUs, this.replyUs, this.reply, this.frame, this.score, this.cbUs, this.devUs, this.owdUs);

  /// The marker's packet on the bus, on the host's clock: the command reached the board one
  /// console transit after it was sent, and the board measured the rest.
  double get busUs => sentUs + owdUs + reply.busUs!;
  bool get found => frame != null && cbUs != null;

  /// Bus to the app's capture callback.
  double? get usbInMs => found ? _ms(cbUs! - busUs) : null;
  double? get busToDeviceMs => devUs == null ? null : _ms(devUs! - busUs);
  double? get deviceToCallbackMs => devUs == null || cbUs == null ? null : _ms(cbUs! - devUs!);
}

/// The usb-in analysis (pure: also fed by the simulation and the tests).
Map<String, Object?> usbInSummary(List<UsbInTrial> trials, {required List<double> rttMs, required List<double> transitMs, required double owdUs}) {
  final sent = trials.where((t) => t.reply.sent).toList();
  final found = sent.where((t) => t.found).toList();
  final lat = [for (final t in found) t.usbInMs!];
  final levels = [for (final t in sent) t.reply.level!];
  return {
    'markers': {
      'asked': trials.length,
      'sent': sent.length,
      'found': found.length,
      'lost': trials.where((t) => t.reply.status == 'lost').length,
      'not_streaming': trials.where((t) => t.reply.status == 'not streaming').length,
      'score_min': found.isEmpty ? null : _r3(found.map((t) => t.score!).reduce(math.min)),
    },
    'console': {'echoes': rttMs.length, 'rtt_ms': _st(rttMs), 'transit_ms': _st(transitMs), 'one_way_ms': owdUs.isFinite ? _r3(owdUs / 1000) : null},
    'usb_in_ms': {
      'how': 'measured: the marker packet on the bus (command sent + console one-way + the board\'s own time from the command to the marker\'s IN transfer) to the start of the app\'s capture callback that carried it',
      ...?Stats.of(lat)?.toJson(),
    },
    'bus_to_device_timestamp_ms': {'how': 'measured: to the input driver\'s own time of that frame (WASAPI QPC position, Core Audio host time)', ...?Stats.of([for (final t in found) ?t.busToDeviceMs])?.toJson()},
    'device_timestamp_to_callback_ms': {'how': 'measured on the host clock alone (no console uncertainty)', ...?Stats.of([for (final t in found) ?t.deviceToCallbackMs])?.toJson()},
    'board_command_to_bus_ms': {'how': 'measured by the board (DWT): OUT packet of the command to the marker\'s IN transfer', ...?Stats.of([for (final t in sent) t.reply.busUs! / 1000])?.toJson()},
    'board_ring_level_frames': {'how': 'reported by the board: its ring before the marker\'s packet', ...?Stats.of(levels)?.toJson()},
    'board_part_ms': {
      'how': 'reported: a synth sample\'s wait in the board\'s ring ((level - 24) / 48) + 1.23 ms packet and bus (doc/usb_audio.md)',
      ...?Stats.of(levels.map(boardPartMs))?.toJson(),
    },
    'synth_to_app_ms': {
      'how': 'board part (reported) + usb_in (measured), per marker',
      ...?Stats.of([for (final t in found) boardPartMs(t.reply.level!) + t.usbInMs!])?.toJson(),
    },
  };
}

/// Opens the Striso's input as the app does (ThroughPc, Through PC off), exclusive or shared, and
/// sends [n] markers.
Future<Map<String, Object?>> runUsbIn(BenchEnv env, {required bool exclusive, int n = 50}) async {
  final b = env.board;
  if (b == null) return {'skipped': 'no board console'};
  // Through PC off: the app opens the input alone for a recording (into a scratch folder, deleted)
  final tmp = Directory.systemTemp.createTempSync('striso_bench_');
  final pc = ThroughPc(backend: env.audio, prefs: env.prefs.copyWith(through: false, exclusive: exclusive), log: (s) => env.log('  $s'), recordingsDir: () => tmp.path);
  pc.start();
  pc.startRecording();
  final ok = await _until(() => pc.state == ThroughState.running && pc.st.captureRate > 0, ms: 10000);
  if (!ok) {
    final why = pc.message;
    pc.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    return {'skipped': 'the Striso input did not open: $why'};
  }
  final st0 = pc.st;
  final probe = ProbeCollector(env.audio, inRate: st0.captureRate.toDouble())..start();
  await _sleep(400);
  final before = await b.usbStats();
  final cl = await consoleLatency(b);
  final trials = <(Exchange<MarkerReply>, int)>[];
  for (var i = 0; i < n; i++) {
    final e = await b.marker();
    trials.add((e, i));
    await _sleep(40 + (i * 7) % 23); // spread over the frame phase
  }
  await _sleep(300);
  probe.stop();
  final after = await b.usbStats();
  final st = pc.st;
  pc.stopRecording();
  await _sleep(200);
  pc.dispose();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  final out = <UsbInTrial>[];
  for (final (e, _) in trials) {
    final r = e.reply ?? const MarkerReply(0, 'no reply');
    double? frame, score, cb, dev;
    if (r.sent) {
      final from = probe.cap.frameAt(e.sentUs);
      if (from != null) {
        final f = probe.find(0, from, from + (0.25 * st0.captureRate).round());
        if (f != null) {
          frame = f.frame;
          score = f.hit.score;
          cb = probe.cap.callbackUs(f.frame)?.toDouble();
          dev = probe.cap.deviceUs(f.frame);
        }
      }
    }
    out.add(UsbInTrial(e.sentUs, e.writtenUs, e.replyUs, r, frame, score, cb, dev, cl.owdUs));
  }
  return {
    'mode': exclusive ? 'exclusive' : 'shared',
    'capture': {..._captureInfo(st), 'exclusive_asked': exclusive},
    ...usbInSummary(out, rttMs: cl.rttMs, transitMs: cl.transitMs, owdUs: cl.owdUs),
    'input_discontinuities': probe.cap.discontinuities(),
    'probe_lost': st.probeLost,
    'board_before': _boardStatsJson(before),
    'board_during': _boardStatsJson(after),
  };
}

// ------------------------------------------------------------------------------------- out

String outputNameOf(List<AudioDevice> outs, String? chosen) =>
    chosen != null && outs.any((d) => d.name == chosen) ? chosen : (outs.where((d) => d.isDefault).firstOrNull?.name ?? '');

Future<List<AudioDevice>> _devices(NativeAudioBackend a) async {
  final g = a.status().devicesGen;
  a.requestDevices();
  await _until(() => a.status().devicesGen != g, ms: 5000);
  return a.devices(capture: false);
}

/// Opens the output alone and plays silence (the guard on) for [seconds]: its latency by its own
/// clock, per share mode and buffer size. [periods]: frames, or 0 for Auto (what the app's Auto
/// starts this output at).
Future<Map<String, Object?>> runOut(BenchEnv env, {List<bool> modes = const [true, false], List<int> periods = const [128, 256, 0], double seconds = 3}) async {
  final a = env.audio;
  a.silenceGuard(true);
  if (!a.init()) return {'skipped': 'the audio system did not start'};
  final outs = await _devices(a);
  final name = outputNameOf(outs, env.prefs.output);
  final dev = outs.where((d) => d.name == name).firstOrNull;
  final busy = a.outputBusy(name);
  final results = <Map<String, Object?>>[];
  final notes = <String>[];
  var openSeconds = 0.0;
  for (final excl in modes) {
    if (excl && !Platform.isWindows && !env.sim) {
      notes.add('exclusive mode is Windows only');
      continue;
    }
    if (excl && busy > 0) {
      notes.add('exclusive skipped: $busy other program${busy == 1 ? '' : 's'} playing to "$name" (never taken from them); measured shared only');
      continue;
    }
    for (final p0 in periods) {
      if (openSeconds + seconds > maxOutputSeconds) {
        notes.add('stopped: the output was open ${openSeconds.toStringAsFixed(1)} s (at most $maxOutputSeconds s per run)');
        break;
      }
      var p = p0;
      if (p0 == 0) {
        final ab = AutoBuffer();
        final key = '${dev?.id ?? 'default'}|${excl ? 'exclusive' : 'shared'}';
        ab.step(now: DateTime.now(), key: key, mem: env.prefs.autoMemory[key] ?? AutoMemory.none, playing: false, dropouts: 0, level: 0, deviceBuffer: 0, deviceMin: excl ? (dev?.devMin ?? 0) : 0);
        p = ab.current;
      }
      if (!a.status().silenceGuard) throw StateError('the silence guard is off: refusing to open an output');
      final gen = a.configure(AudioConfig(run: true, output: name, period: p, exclusiveOutput: excl, outputOnly: true));
      final opened = await _until(() => a.status().configGen - gen >= 0 && a.status().playback != DevState.closed, ms: 5000);
      final s0 = a.status();
      if (!opened || s0.playback != DevState.running) {
        results.add({'exclusive_asked': excl, 'period_asked': p, 'auto': p0 == 0, 'error': 'the output did not open (${s0.playbackResult})'});
        continue;
      }
      final probe = ProbeCollector(a, outRate: s0.playbackRate.toDouble())..start();
      final sw = Stopwatch()..start();
      await _sleep((seconds * 1000).round());
      probe.stop();
      final s = a.status();
      a.configure(AudioConfig.off);
      await _until(() => a.status().playback == DevState.closed, ms: 3000);
      openSeconds += sw.elapsedMilliseconds / 1000;
      final lat = probe.play.firstFrameLatencies();
      final rate = s.playbackRate > 0 ? s.playbackRate : 48000;
      final reportedDev = s.playbackStreamLatency / rate * 1000;
      final mean = probe.play.callbacks.isEmpty ? 0.0 : probe.play.callbacks.map((m) => m.n).reduce((x, y) => x + y) / probe.play.callbacks.length / 2 / rate * 1000;
      if (s.silenceViolations != 0) throw StateError('silence guard: ${s.silenceViolations} non-zero output samples were forced to 0');
      results.add({
        'exclusive_asked': excl,
        'exclusive': s.playbackExclusive,
        if (excl && !s.playbackExclusive) 'shared_because': s.playbackExclResult == -17 ? 'another program holds it exclusively' : 'it would not open exclusively (${s.playbackExclResult})',
        'period_asked': p,
        'auto': p0 == 0,
        'rate': rate,
        'buffer_frames': s.playbackBuffer,
        'device_min_frames': s.playbackDevMin,
        'callback_frames': _st(probe.play.callbacks.map((m) => m.n)),
        'callbacks': probe.play.callbacks.length,
        'first_frame_latency_ms': {
          'how': Platform.isMacOS
              ? 'measured: callback to Core Audio\'s presentation time of its first frame'
              : 'measured: callback to when its first frame plays, by the output\'s own clock (IAudioClock position and its QPC time)',
          ...?Stats.of(lat)?.toJson(),
        },
        'mean_sample_latency_ms': lat.isEmpty ? null : _r3(median(lat) + mean + (Platform.isMacOS ? reportedDev : 0)),
        'reported_stream_latency_ms': _r3(reportedDev),
        'reported_out_ms': _r3(s.outMs),
        if (Platform.isMacOS) 'note': 'macOS: mean_sample_latency adds the reported device + stream + safety latency (after presentation)',
        'clock': s.playbackClock,
        'silence_violations': s.silenceViolations,
        'cpu_playback_busy_percent': null,
      });
    }
  }
  a.shutdown();
  return {'output': name, 'transport': dev?.transport.name, 'other_programs_playing': busy, 'configs': results, 'output_open_s': _r3(openSeconds), 'notes': notes};
}

// ------------------------------------------------------------------------------------- through

class _Cpu {
  final int wall, cpuCap, cpuPlay, busyCap, busyPlay;
  _Cpu(this.wall, AudioStatus s) : cpuCap = s.cpuCaptureUs, cpuPlay = s.cpuPlaybackUs, busyCap = s.busyCaptureUs, busyPlay = s.busyPlaybackUs;
  static double _pct(int a, int b, int wall) => wall <= 0 ? 0 : _r3(((b - a) & 0xFFFFFFFF) / wall * 100);
  Map<String, Object?> to(_Cpu e) => {
    'how': 'measured: CPU time of each device thread (GetThreadTimes; thread CPU clock on macOS, coarse on Windows: 15.6 ms ticks) and time inside this library\'s callbacks, over the run',
    'capture_thread_percent': _pct(cpuCap, e.cpuCap, e.wall - wall),
    'playback_thread_percent': _pct(cpuPlay, e.cpuPlay, e.wall - wall),
    'capture_callbacks_percent': _pct(busyCap, e.busyCap, e.wall - wall),
    'playback_callbacks_percent': _pct(busyPlay, e.busyPlay, e.wall - wall),
  };
}

/// Through PC as the app runs it (Auto buffer, the user's exclusive settings, the board's Auto
/// buffer through BoardAudioLink) with the output gain at 0 and the silence guard on, for
/// [seconds], a marker every [markerEvery] s followed through to the output. [boardTargets]: a
/// fixed sequence of board ring targets instead of Auto, each for [seconds] (the Stct sweep).
Future<Map<String, Object?>> runThrough(BenchEnv env, {double seconds = 25, double markerEvery = 1, List<int>? boardTargets, String label = 'through'}) async {
  final a = env.audio;
  final b = env.board;
  a.silenceGuard(true);
  // never take an output another program is playing to
  if (!a.init()) return {'skipped': 'the audio system did not start'};
  final outs = await _devices(a);
  final name = outputNameOf(outs, env.prefs.output);
  final busy = a.outputBusy(name);
  final exclOut = env.prefs.exclusiveOutput && busy <= 0;
  final notes = <String>[if (env.prefs.exclusiveOutput && busy > 0) 'exclusive output not used: $busy other program${busy == 1 ? '' : 's'} playing to "$name"'];
  final log = <String>[];
  final pc = ThroughPc(
    backend: a,
    prefs: env.prefs.copyWith(through: true, gainDb: AudioPrefs.minDb, exclusiveOutput: exclOut, boardBuffer: boardTargets?.first ?? env.prefs.boardBuffer),
    log: (s) {
      log.add(s);
      env.log('  $s');
    },
  );
  if (gainOf(pc.prefs.gainDb) != 0) throw StateError('through: the gain is not 0');
  var running = true;
  final boardStats = <(int, UsbAudioStats)>[];
  BoardAudioLink? link;
  pc.start();
  final ok = await _until(() => pc.playing && pc.st.streaming, ms: 15000);
  if (!ok) {
    final why = '${pc.message} ${pc.outputNote ?? ''}';
    pc.dispose();
    return {'skipped': 'Through PC did not start: $why'};
  }
  if (!a.status().silenceGuard || a.status().gain != 0) {
    pc.dispose();
    throw StateError('through: the silence guard is off or the gain is not 0');
  }
  if (b != null) {
    link = BoardAudioLink(audio: pc, getStats: b.usbStats, setTarget: b.setTarget, alive: () => running, log: (s) => env.log('  $s'), onStats: (s) => boardStats.add((pc.boardTargetWanted, s)));
    unawaited(link.run());
  }
  final st0 = pc.st;
  final probe = ProbeCollector(a, inRate: st0.captureRate.toDouble(), outRate: st0.playbackRate.toDouble())..start();
  final c0 = _Cpu(a.clockUs(), a.status());
  final markers = <Exchange<MarkerReply>>[];
  final pending = <Exchange<MarkerReply>>[];
  final shown = <int, double>{}; // what the app showed (Setup > Audio) when each marker was sent
  final owd = b == null ? double.nan : (await consoleLatency(b, n: 10)).owdUs;
  // the markers through the whole path: bus -> input -> ring -> output -> plays
  final e2e = <double>[], inPart = <double>[], ringPart = <double>[], outPart = <double>[], levels = <double>[], shownDiff = <double>[];
  var found = 0, foundOut = 0;
  void follow(Exchange<MarkerReply> e) {
    final r = e.reply;
    if (r == null || !r.sent) return;
    final bus = e.sentUs + owd + r.busUs!;
    final from = probe.cap.frameAt(e.sentUs);
    if (from == null) return;
    final fi = probe.find(0, from, from + (0.25 * st0.captureRate).round());
    if (fi == null) return;
    found++;
    final cb = probe.cap.callbackUs(fi.frame);
    // the output frame that carried it (the output tap, before the gain)
    final ofrom = probe.play.callbacks.where((m) => m.tUs >= e.sentUs).firstOrNull?.frame;
    final fo = ofrom == null ? null : probe.find(1, ofrom, ofrom + (0.4 * st0.playbackRate).round());
    if (fo == null || cb == null) return;
    final play = probe.play.playUs(fo.frame);
    final ocb = probe.play.callbacks.where((m) => m.frame <= fo.frame && fo.frame < m.frame + m.n).firstOrNull?.tUs;
    if (play == null || ocb == null) return;
    foundOut++;
    levels.add(r.level!.toDouble());
    inPart.add(_ms(cb - bus));
    ringPart.add(_ms(ocb - cb));
    outPart.add(_ms(play - ocb));
    e2e.add(boardPartMs(r.level!) + _ms(play - bus));
    final sh = shown[e.sentUs];
    if (sh != null && sh > 0) shownDiff.add(sh - e2e.last);
  }

  void settle({bool all = false}) {
    final now = a.clockUs();
    while (pending.isNotEmpty && (all || now - pending.first.sentUs > 800000)) {
      follow(pending.removeAt(0));
    }
    // a long run keeps the last few seconds of audio only
    for (var k = 0; k < 2; k++) {
      final t = probe.taps[k];
      final keep = (5 * (k == 0 ? st0.captureRate : st0.playbackRate)).round();
      if (pending.isEmpty && t.end > keep) t.trimBefore(t.end - keep);
    }
    if (probe.play.callbacks.length > 20000 && pending.isEmpty) probe.play.callbacks.removeRange(0, probe.play.callbacks.length - 4000);
  }

  final targets = boardTargets ?? [0];
  final perTarget = <Map<String, Object?>>[];
  for (final tgt in targets) {
    if (boardTargets != null) {
      pc.setBoardBuffer(tgt);
      await _sleep(4500); // the link sets it at its next poll; the change itself may prime once
    }
    final from = boardStats.length;
    final sw = Stopwatch()..start();
    var nextMark = 0.5;
    while (sw.elapsedMilliseconds < seconds * 1000) {
      if (b != null && markerEvery > 0 && sw.elapsedMilliseconds >= nextMark * 1000) {
        final e = await b.marker();
        markers.add(e);
        pending.add(e);
        shown[e.sentUs] = pc.breakdown.total;
        nextMark += markerEvery;
      }
      await _sleep(25);
      settle();
    }
    if (boardTargets != null) {
      final win = boardStats.sublist(from).where((e) => e.$1 == tgt).map((e) => e.$2).toList();
      perTarget.add({
        'target': tgt,
        'polls': win.length,
        'underruns': win.fold<int>(0, (x, s) => x + (s.underruns ?? 0)),
        'host_skipped': win.fold<int>(0, (x, s) => x + (s.hostSkipped ?? 0)),
        'not_ready': win.fold<int>(0, (x, s) => x + (s.notReady ?? 0)),
        'ring_min': win.isEmpty ? null : win.map((s) => s.ringMin ?? 999).reduce(math.min),
        'synth_blocks_lost_since_boot': win.isEmpty ? null : win.last.blocksLost,
      });
    }
  }
  await _sleep(900);
  probe.drain();
  settle(all: true);
  probe.stop();
  final c1 = _Cpu(a.clockUs(), a.status());
  final st = pc.st;
  final period = pc.period, auto = pc.prefs.isAuto, boardWanted = pc.boardTargetWanted;
  final bd = pc.breakdown;
  final drops = {for (final s in DropSide.values) s.name: pc.dropouts.where((d) => d.side == s).length};
  final dropList = [for (final d in pc.dropouts.take(100)) {'at': d.at.toIso8601String(), 'side': d.side.name, 'why': d.why}];
  running = false;
  pc.dispose();
  if (st.silenceViolations != 0) throw StateError('silence guard: ${st.silenceViolations} non-zero output samples were forced to 0');
  final cpu = c0.to(c1);
  return {
    'label': label,
    'seconds': seconds * targets.length,
    'output': name,
    'exclusive_output_asked': exclOut,
    'capture': _captureInfo(st),
    'playback': {'exclusive': st.playbackExclusive, 'rate': st.playbackRate, 'buffer_frames': st.playbackBuffer, 'clock': st.playbackClock},
    'auto': {'buffer_auto': auto, 'period_frames': period, 'board_target_frames': boardWanted, 'board_target_set': link?.targetSet},
    'markers': {'asked': markers.length, 'found_in_input': found, 'followed_to_output': foundOut},
    'end_to_end_ms': {
      'how': 'board part (reported: ring level) + measured: marker on the bus to when its output frame plays by the output\'s clock',
      ...?Stats.of(e2e)?.toJson(),
    },
    'parts_ms': {
      'board': {'how': 'reported (ring level)', ...?Stats.of(levels.map(boardPartMs))?.toJson()},
      'usb_in': {'how': 'measured: bus to the capture callback', ...?Stats.of(inPart)?.toJson()},
      'ring': {'how': 'measured: capture callback to the playback callback that took the marker', ...?Stats.of(ringPart)?.toJson()},
      'out': {'how': 'measured: playback callback to when that frame plays (output clock)', ...?Stats.of(outPart)?.toJson()},
    },
    'app_shown_minus_measured_ms': {'how': 'the total the app showed when each marker was sent, minus the measured end to end of that marker', ...?Stats.of(shownDiff)?.toJson()},
    'app_breakdown_ms': {'how': 'what the app shows (Setup > Audio): reported and modelled', 'input': _r3(bd.input), 'ring': _r3(bd.ring), 'output': _r3(bd.output), 'usb': _r3(bd.usb), 'usb_measured': bd.usbMeasured, 'total': _r3(bd.total)},
    'dropouts': {
      'board': drops['board'],
      'input': drops['input'],
      'output': drops['output'],
      'input_discontinuities_reported': st.capDiscontinuities,
      'native': {'underruns': st.underruns, 'overruns': st.overruns, 'resyncs': st.resyncs, 'out_glitches': st.outGlitches, 'in_late': st.inLate, 'out_late': st.outLate},
      'events': dropList,
    },
    'board_polls': boardStats.length,
    'board_underruns': boardStats.fold<int>(0, (x, e) => x + (e.$2.underruns ?? 0)),
    'board_host_skipped': boardStats.fold<int>(0, (x, e) => x + (e.$2.hostSkipped ?? 0)),
    'board_blocks_lost_since_boot': boardStats.isEmpty ? null : boardStats.last.$2.blocksLost,
    if (boardTargets != null) 'targets': perTarget,
    'cpu': cpu,
    'silence_violations': st.silenceViolations,
    'gain': st.gain,
    'level_in_peak_hint': 'the board was ${st.levelL > 0.001 || st.levelR > 0.001 ? 'playing (input not silent: someone may be playing)' : 'silent'} at the end',
    'notes': notes,
    'log_tail': log.length > 30 ? log.sublist(log.length - 30) : log,
  };
}
