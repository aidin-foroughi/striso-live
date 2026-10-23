// "Through PC": the Striso's USB audio input played through the computer, and recorded to WAV.
// A state machine over an AudioBackend, ticked about 20 times a second: it finds the Striso's
// input, asks the native side for the wanted state, reads the status (levels, latency,
// dropouts), and comes back by itself after an unplug or a restart of the board. No audio passes
// through Dart.
//
// The buffer is Auto by default (auto_buffer.dart): safe at first, tighter while it plays cleanly,
// one step back at a dropout, remembered per output. Every dropout the native side reports comes
// with its cause and time (the event log) and is counted by side: the board (its own counters,
// polled over the console by the app), the input (late, or dropped on a full ring), the output.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'auto_buffer.dart';
import 'backend.dart';

enum ThroughState {
  /// No audio library, or the audio system did not start.
  unavailable,

  /// Neither Through PC nor a recording is on.
  off,

  /// Looking for the Striso's input (not seen since this started).
  searching,

  /// The board is on USB but shows no audio input: its firmware predates USB audio.
  noUsbAudio,

  /// The input was there and is gone (unplugged, the board restarting), or the chosen one is not
  /// connected: waiting for it.
  missing,

  /// macOS is asking the user about audio input.
  permission,

  /// macOS does not allow audio input for the app.
  denied,

  /// Asked the native side; not open yet.
  starting,

  /// The input is open (and, with Through PC on, playing to the output).
  running,

  /// The input is there but would not open; retried.
  failed,
}

/// The persisted choices.
class AudioPrefs {
  final bool through;

  /// Exact input name; null: the Striso, found by itself.
  final String? input;

  /// Exact output name; null: the system default.
  final String? output;

  /// Frames per device period, or [auto] (0).
  final int period;
  final double gainDb;

  /// Windows: the input in exclusive mode first (lower latency, the device's own 24 bit).
  final bool exclusive;

  /// Windows: the output in exclusive mode when it is wired (not Bluetooth), falling back to shared
  /// when another program holds it. Off: always shared.
  final bool exclusiveOutput;

  /// What Auto learned, per output (AutoMemory as JSON, by [ThroughPc.outputKey]).
  final Map<String, AutoMemory> autoMemory;

  const AudioPrefs({
    this.through = false,
    this.input,
    this.output,
    this.period = auto,
    this.gainDb = -6,
    this.exclusive = true,
    this.exclusiveOutput = true,
    this.autoMemory = const {},
  });

  static const auto = 0;
  static const periods = [64, 128, 256, 512];
  static const minDb = -40.0, maxDb = 6.0;

  /// The settings' version: 2 made Auto and exclusive output the defaults.
  static const version = 2;

  bool get isAuto => period == auto;

  static const _keep = Object();

  AudioPrefs copyWith({
    bool? through,
    Object? input = _keep,
    Object? output = _keep,
    int? period,
    double? gainDb,
    bool? exclusive,
    bool? exclusiveOutput,
    Map<String, AutoMemory>? autoMemory,
  }) => AudioPrefs(
    through: through ?? this.through,
    input: identical(input, _keep) ? this.input : input as String?,
    output: identical(output, _keep) ? this.output : output as String?,
    period: period ?? this.period,
    gainDb: gainDb ?? this.gainDb,
    exclusive: exclusive ?? this.exclusive,
    exclusiveOutput: exclusiveOutput ?? this.exclusiveOutput,
    autoMemory: autoMemory ?? this.autoMemory,
  );

  Map<String, Object?> toJson() => {
    'v': version,
    'through': through,
    if (input != null) 'input': input,
    if (output != null) 'output': output,
    'period': period,
    'gainDb': gainDb,
    'exclusive': exclusive,
    'exclusiveOutput': exclusiveOutput,
    if (autoMemory.isNotEmpty) 'auto': {for (final e in autoMemory.entries) e.key: e.value.toJson()},
  };

  static AudioPrefs fromJson(Object? j) {
    if (j is! Map) return const AudioPrefs();
    final v = (j['v'] as num?)?.toInt() ?? 1;
    final p = (j['period'] as num?)?.toInt() ?? auto;
    final g = (j['gainDb'] as num?)?.toDouble() ?? -6;
    final mem = <String, AutoMemory>{};
    final a = j['auto'];
    if (a is Map) {
      for (final e in a.entries) {
        if (e.key is String) mem[e.key as String] = AutoMemory.fromJson(e.value);
      }
    }
    return AudioPrefs(
      through: j['through'] == true,
      input: j['input'] is String && (j['input'] as String).isNotEmpty ? j['input'] as String : null,
      output: j['output'] is String && (j['output'] as String).isNotEmpty ? j['output'] as String : null,
      // settings from before Auto: Auto (the old fixed size dropped out; Auto finds the best)
      period: v < 2 ? auto : (p == auto || periods.contains(p) ? p : auto),
      gainDb: g.isFinite ? g.clamp(minDb, maxDb) : -6,
      exclusive: j['exclusive'] != false,
      // before 2 the output was shared unless asked: now exclusive on wired outputs unless turned off
      exclusiveOutput: v < 2 ? true : j['exclusiveOutput'] != false,
      autoMemory: mem,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioPrefs &&
      other.through == through &&
      other.input == input &&
      other.output == output &&
      other.period == period &&
      other.gainDb == gainDb &&
      other.exclusive == exclusive &&
      other.exclusiveOutput == exclusiveOutput &&
      _sameMem(other.autoMemory, autoMemory);

  static bool _sameMem(Map<String, AutoMemory> a, Map<String, AutoMemory> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  int get hashCode => Object.hash(through, input, output, period, gainDb, exclusive, exclusiveOutput, autoMemory.length);
}

/// The board's own counters (console StcU), as the app parsed them; null fields: not reported.
class BoardAudioStats {
  final int? sent, missed, underruns, overruns, primes;

  /// The board's ring before each packet (frames): filtered level, and min..max since the last poll.
  final double? ringFiltered;
  final int? ringMin, ringMax, ringTarget;
  final bool? streaming;
  const BoardAudioStats({
    this.sent,
    this.missed,
    this.underruns,
    this.overruns,
    this.primes,
    this.ringFiltered,
    this.ringMin,
    this.ringMax,
    this.ringTarget,
    this.streaming,
  });

  /// Dropouts on the board's side since the last poll (its ring ran dry or overflowed).
  int get drops => (underruns ?? 0) + (overruns ?? 0);
}

/// The Striso's input among [inputs]: by USB VID/PID where the system says, else by name.
/// [chosen] (an exact name) overrides; null when that one is not there.
AudioDevice? pickInput(List<AudioDevice> inputs, String? chosen) {
  if (chosen != null) return inputs.where((d) => d.name == chosen).firstOrNull;
  return inputs.where((d) => d.isStriso).firstOrNull ??
      inputs.where((d) => d.name.toLowerCase().contains('striso synth')).firstOrNull ??
      inputs.where((d) => d.name.toLowerCase().contains('striso')).firstOrNull;
}

/// dB to the native gain (the bottom of the range is silence).
double gainOf(double db) => db <= AudioPrefs.minDb ? 0 : math.pow(10, db / 20).toDouble();

/// "Striso 2026-10-23 14.02.11.wav" (no colons: Windows).
String recordingName(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Striso ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}.wav';
}

/// Tone of the status line, for its colour.
enum Tone { quiet, ok, busy, problem }

/// Where a dropout happened.
enum DropSide { board, input, output }

class Dropout {
  final DateTime at;
  final DropSide side;
  final String why;
  const Dropout(this.at, this.side, this.why);
}

/// The latency through the computer, by part (ms).
class Breakdown {
  final double input, ring, output, usb;

  /// The USB part is the board's ring as it reported it (else its target, an estimate).
  final bool usbMeasured;
  const Breakdown(this.input, this.ring, this.output, this.usb, {this.usbMeasured = false});
  double get total => input + ring + output + usb;
}

class ThroughPc {
  final AudioBackend? backend;
  final bool Function() boardOnUsb;
  final void Function(AudioPrefs)? onPrefs;
  final void Function(String)? log;
  final DateTime Function() _now;

  /// The folder recordings go to (created when needed).
  final String Function()? recordingsDir;
  final Duration tickEvery;

  /// Windows semantics (exclusive mode) apply; false on macOS.
  final bool windows;
  final AutoBuffer autoBuffer;

  AudioPrefs _prefs;
  ThroughState state = ThroughState.off;
  String message = '';
  Tone tone = Tone.quiet;

  /// Output trouble while the input runs (null: none).
  String? outputNote;

  /// A quiet remark about the output (shared because another program holds it; Bluetooth).
  String? outputHint;
  AudioStatus st = AudioStatus.idle;
  List<AudioDevice> inputs = const [], outputs = const [];

  // recording
  String? recordingPath, lastRecording, recordNote;
  bool _recWanted = false, _recSeenOn = false, _recStopping = false;
  DateTime _recAskedAt = DateTime(0);

  // dropouts
  final dropouts = <Dropout>[];
  int _evSeq = 0;
  BoardAudioStats? board;
  int boardDropsTotal = 0;
  DateTime? _boardAt;
  DateTime _summaryAt = DateTime(0);

  final _changed = <void Function()>[], _levels = <void Function()>[];
  Timer? _timer;
  bool _inited = false, _initFailed = false, _disposed = false;
  bool _watchDevices = false, _everRan = false, _haveDevices = false;
  int _devGenSeen = -1, _gen = 0;
  bool _enumPending = false;
  DateTime _enumAskedAt = DateTime(0), _devicesAt = DateTime(0), _sentAt = DateTime(0), _troubleAt = DateTime(0);
  DateTime? _boardSince;
  AudioConfig _sent = AudioConfig.off;
  double _sentGain = -1;
  bool _wantResend = false;
  String _lastLogged = '';

  ThroughPc({
    required this.backend,
    AudioPrefs prefs = const AudioPrefs(),
    bool Function()? boardOnUsb,
    this.onPrefs,
    this.log,
    this.recordingsDir,
    DateTime Function()? clock,
    this.tickEvery = const Duration(milliseconds: 50),
    bool? windows,
    AutoTiming autoTiming = const AutoTiming(),
  }) : _prefs = prefs,
       boardOnUsb = boardOnUsb ?? (() => false),
       _now = clock ?? DateTime.now,
       windows = windows ?? Platform.isWindows,
       autoBuffer = AutoBuffer(timing: autoTiming) {
    state = backend == null ? ThroughState.unavailable : ThroughState.off;
    _describe(false);
  }

  AudioPrefs get prefs => _prefs;
  bool get available => backend != null && !_initFailed;
  bool get recording => recordingPath != null;
  bool get through => _prefs.through;

  /// Seconds recorded so far.
  double get recordSeconds => st.recordFrames / (st.captureRate > 0 ? st.captureRate : 48000);

  /// The input is open and the output plays it.
  bool get playing => state == ThroughState.running && _prefs.through && st.playback == DevState.running;

  /// Input peak 0..1 (both channels).
  double get level => math.max(st.levelL, st.levelR);

  /// The period in use: Auto's choice, or the manual one.
  int get period => _prefs.isAuto ? autoBuffer.current : _prefs.period;

  void addListener(void Function() f) => _changed.add(f);
  void removeListener(void Function() f) => _changed.remove(f);

  /// Called on every tick while something runs (meters).
  void addLevelListener(void Function() f) => _levels.add(f);
  void removeLevelListener(void Function() f) => _levels.remove(f);

  void _notify() {
    for (final f in List.of(_changed)) {
      f();
    }
  }

  /// Starts ticking (the app; tests call [tick] themselves).
  void start() {
    if (backend == null || _timer != null) return;
    _timer = Timer.periodic(tickEvery, (_) => tick());
    tick();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    final b = backend;
    if (b != null && _inited) {
      if (recording) b.recordStop();
      b.shutdown(); // finishes a recording's file, closes the devices
    }
    _inited = false;
  }

  // ---------------------------------------------------------------------------------- choices

  void _setPrefs(AudioPrefs p) {
    if (p == _prefs) return;
    _prefs = p;
    onPrefs?.call(p);
    _notify();
    tick();
  }

  void setThrough(bool on) => _setPrefs(_prefs.copyWith(through: on));
  void setInput(String? name) => _setPrefs(_prefs.copyWith(input: name));
  void setOutput(String? name) => _setPrefs(_prefs.copyWith(output: name));

  /// Frames per period, or [AudioPrefs.auto].
  void setPeriod(int frames) => _setPrefs(_prefs.copyWith(period: frames));
  void setExclusive(bool on) => _setPrefs(_prefs.copyWith(exclusive: on));
  void setExclusiveOutput(bool on) => _setPrefs(_prefs.copyWith(exclusiveOutput: on));
  void setGainDb(double db) => _setPrefs(_prefs.copyWith(gainDb: db.clamp(AudioPrefs.minDb, AudioPrefs.maxDb)));

  /// The device lists stay fresh while a picker shows them (from the next tick: this may be called
  /// while widgets build).
  void watchDevices(bool on) {
    _watchDevices = on;
    if (on) _enumAskedAt = DateTime(0);
  }

  void startRecording() {
    if (recording || _recWanted || backend == null) return;
    _recWanted = true;
    recordNote = null;
    _notify();
    tick();
  }

  void stopRecording() {
    if (!recording) {
      _recWanted = false;
      _notify();
      return;
    }
    if (_recStopping) return;
    _recStopping = true;
    backend!.recordStop();
    _notify();
  }

  // ---------------------------------------------------------------------------------- outputs

  /// The output that plays: the chosen one when it is connected, else the default.
  AudioDevice? get outputDevice {
    final o = _prefs.output;
    if (o != null) {
      final d = outputs.where((d) => d.name == o).firstOrNull;
      if (d != null) return d;
    }
    return outputs.where((d) => d.isDefault).firstOrNull;
  }

  /// Bluetooth: by the open output's transport, else by the device list.
  bool get outputBluetooth => (playing && st.playbackTransport == AudioTransport.bluetooth) || (outputDevice?.isBluetooth ?? false);

  /// Exclusive output is asked for: Windows, the setting on, and a wired output.
  bool get wantExclusiveOutput => windows && _prefs.exclusiveOutput && !outputBluetooth;

  /// Auto's memory is per output and share mode.
  String get outputKey => '${outputDevice?.id ?? (_prefs.output ?? 'default')}|${wantExclusiveOutput ? 'exclusive' : 'shared'}';

  // ---------------------------------------------------------------------------------- the tick

  void tick() {
    if (_disposed) return;
    final b = backend;
    if (b == null) return;
    final t = _now();
    final want = _prefs.through || _recWanted || recording;
    if (!want && !_watchDevices && !_inited) {
      _setState(ThroughState.off);
      return;
    }
    if (!_inited) {
      if (_initFailed) return;
      _inited = b.init();
      if (!_inited) {
        _initFailed = true;
        _log('audio: the audio system did not start (${b.description})');
        _setState(ThroughState.unavailable, msg: 'The computer’s audio system did not start.');
        return;
      }
      _log('audio: ${b.description}');
    }
    st = b.status();
    final devicesChanged = _devicesTick(t, want);
    _eventsTick(t);

    final g = gainOf(_prefs.gainDb);
    if (g != _sentGain) {
      b.setGain(g);
      _sentGain = g;
    }

    if (!want) {
      if (_sent.run) _send(AudioConfig.off, t);
      _setState(ThroughState.off);
      if (devicesChanged) _notify();
      _pingLevels();
      return;
    }

    final applied = st.configGen - _gen >= 0 && _sent.run;
    // the input: open it, or keep looking
    final running = applied && st.capture == DevState.running;
    if (_prefs.isAuto && _haveDevices) _autoTick(t, applied);
    if (!running) {
      _seekInput(t, applied, devicesChanged);
    } else {
      _everRan = true;
      _boardSince = null;
      _wantResend = false;
      _setState(ThroughState.running);
      _keepOutput(t);
    }
    _recordTick(t);
    _describe(applied);
    _summaryTick(t);
    if (devicesChanged) _notify();
    _pingLevels();
  }

  void _autoTick(DateTime t, bool applied) {
    final key = outputKey;
    final mem = _prefs.autoMemory[key] ?? AutoMemory.none;
    final before = autoBuffer.current;
    final playingNow = applied && _sent.period == autoBuffer.current && playing && st.streaming;
    final s = autoBuffer.step(
      now: t,
      key: key,
      mem: mem,
      playing: playingNow,
      dropouts: st.dropouts,
      level: level,
      deviceBuffer: st.playbackBuffer,
    );
    if (s.note != null) _log('audio: ${s.note}');
    if (s.remember != null && s.remember != mem) {
      _setPrefs(_prefs.copyWith(autoMemory: {..._prefs.autoMemory, key: s.remember!}));
    }
    if (autoBuffer.current != before) _notify();
  }

  void _pingLevels() {
    for (final f in List.of(_levels)) {
      f();
    }
  }

  /// Enumeration: on request while looking for the input or while a picker is open.
  bool _devicesTick(DateTime t, bool want) {
    final b = backend!;
    var changed = false;
    if (st.devicesGen != _devGenSeen) {
      if (_devGenSeen != -1 || _enumPending) {
        inputs = b.devices(capture: true);
        outputs = b.devices(capture: false);
        _haveDevices = true;
        _devicesAt = t;
        changed = true;
      }
      _devGenSeen = st.devicesGen;
      _enumPending = false;
    }
    final looking = want && !(st.capture == DevState.running && st.configGen - _gen >= 0);
    final every = looking ? const Duration(milliseconds: 1500) : const Duration(seconds: 3);
    if (_enumPending && t.difference(_enumAskedAt) > const Duration(seconds: 3)) _enumPending = false;
    if (!_enumPending && (looking || _watchDevices || !_haveDevices) && t.difference(_enumAskedAt) >= every) {
      b.requestDevices();
      _enumPending = true;
      _enumAskedAt = t;
    }
    return changed;
  }

  // ---------------------------------------------------------------------------------- events

  /// The event's wall-clock time (the native clock against now).
  DateTime _evTime(DateTime now, AudioEvent e) => st.nowUs > 0 && e.tUs <= st.nowUs ? now.subtract(Duration(microseconds: st.nowUs - e.tUs)) : now;

  static String clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }

  void _eventsTick(DateTime t) {
    if (st.eventSeq == _evSeq) return;
    final evs = backend!.events(_evSeq);
    if (evs.isEmpty) return;
    var logged = 0, more = 0;
    for (final e in evs) {
      _evSeq = e.seq;
      final at = _evTime(t, e);
      if (e.isDropout) dropouts.add(Dropout(at, e.inputSide ? DropSide.input : DropSide.output, e.text));
      // late wake-ups within the buffer and target moves are frequent and harmless: the summary
      // has them; every dropout and everything else is logged with its cause
      final quiet = (e.type == Ev.outLate && e.c == 0) || e.type == Ev.inLate || e.type == Ev.target;
      if (quiet && !e.isDropout) continue;
      if (logged < 20) {
        _log('audio: ${clock(at)} ${e.text}');
        logged++;
      } else {
        more++;
      }
    }
    if (more > 0) _log('audio: ($more more events)');
    _pruneDropouts(t);
  }

  void _pruneDropouts(DateTime t) {
    final cut = t.subtract(const Duration(minutes: 10));
    dropouts.removeWhere((d) => d.at.isBefore(cut));
  }

  /// The board's counters since the last poll (the app polls StcU every 2 s while this plays).
  void boardStats(BoardAudioStats s) {
    final t = _now();
    board = s;
    _boardAt = t;
    final n = s.drops;
    if (n > 0) {
      boardDropsTotal += n;
      final why = [
        if ((s.underruns ?? 0) > 0) '${s.underruns} underrun${s.underruns == 1 ? '' : 's'}',
        if ((s.overruns ?? 0) > 0) '${s.overruns} overrun${s.overruns == 1 ? '' : 's'}',
      ].join(', ');
      for (var i = 0; i < math.min(n, 50); i++) {
        dropouts.add(Dropout(t, DropSide.board, 'board: $why'));
      }
      _log('audio: ${clock(t)} dropout on the board: $why (its ring ${s.ringMin ?? '?'}..${s.ringMax ?? '?'} frames, ${s.missed ?? 0} packets the host missed)');
      _pruneDropouts(t);
      _notify();
    } else if ((s.missed ?? 0) > 0) {
      _log('audio: board: ${s.missed} packets the host did not fetch in time (resent, no samples lost)');
    }
  }

  /// Dropouts in the last minute, by side.
  Map<DropSide, int> dropoutsLastMinute() {
    final t = _now().subtract(const Duration(minutes: 1));
    final out = {for (final s in DropSide.values) s: 0};
    for (final d in dropouts) {
      if (!d.at.isBefore(t)) out[d.side] = out[d.side]! + 1;
    }
    return out;
  }

  /// Once a minute while playing: the timing behind the numbers, for the log.
  void _summaryTick(DateTime t) {
    if (!playing) return;
    if (t.difference(_summaryAt) < const Duration(minutes: 1)) return;
    if (_summaryAt.year > 2000) {
      final m = dropoutsLastMinute();
      _log(
        'audio: last minute: dropouts board ${m[DropSide.board]} · input ${m[DropSide.input]} · output ${m[DropSide.output]}; '
        'input every ${(st.capNominalUs / 1000).toStringAsFixed(2)} ms (longest ${(st.capRecentGapUs / 1000).toStringAsFixed(2)}, ${st.inLate} late), '
        'output every ${(st.playNominalUs / 1000).toStringAsFixed(2)} ms (longest ${(st.playRecentGapUs / 1000).toStringAsFixed(2)}, ${st.outLate} late); '
        'ring ${st.ringMs.toStringAsFixed(1)} ms of target ${st.targetMs.toStringAsFixed(1)}, servo ${st.driftPpm.toStringAsFixed(0)} ppm; '
        '$period frames${_prefs.isAuto ? ' (auto)' : ''}',
      );
    }
    _summaryAt = t;
  }

  /// The latency through the computer by part: input (its wake-up interval and what the system
  /// reports), ring (the passthrough's ring and resampler), output (its buffer and what the system
  /// reports), USB (the board's ring before each 1 ms packet, plus the packet).
  Breakdown get breakdown {
    final b = board;
    final measured = b?.ringFiltered != null && (_boardAt != null && _now().difference(_boardAt!) < const Duration(seconds: 10));
    final ringFrames = measured ? b!.ringFiltered! : (b?.ringTarget ?? 144).toDouble();
    return Breakdown(st.inMs, st.ringMs, st.outMs, ringFrames / 48 + 1, usbMeasured: measured);
  }

  // ---------------------------------------------------------------------------------- devices

  String _outputName() {
    final o = _prefs.output;
    if (o == null) return '';
    if (_haveDevices && !outputs.any((d) => d.name == o)) return ''; // not connected: the default
    return o;
  }

  AudioConfig _config(String input) => AudioConfig(
    run: true,
    input: input,
    output: _outputName(),
    period: period,
    monitor: _prefs.through,
    exclusive: _prefs.exclusive,
    exclusiveOutput: wantExclusiveOutput,
  );

  void _send(AudioConfig c, DateTime t) {
    _gen = backend!.configure(c);
    _sent = c;
    _sentAt = t;
    _wantResend = false;
    _log('audio: $c');
  }

  void _seekInput(DateTime t, bool applied, bool devicesChanged) {
    if (!_haveDevices) {
      _setState(ThroughState.searching);
      return;
    }
    // what the native side said about the last request
    if (applied && _sent.run) {
      final e = st.captureError;
      if (st.capture == DevState.lost) {
        if (!_wantResend) _troubleAt = t;
        _wantResend = true;
        _everRan = true;
      } else if (st.capture == DevState.failed) {
        if (!_wantResend) _troubleAt = t;
        _wantResend = true;
        if (e == AudioErr.permission) {
          final m = st.micPermission;
          _setState(m == Mic.undetermined ? ThroughState.permission : ThroughState.denied);
          if (m != Mic.authorized) return;
        }
      }
    }
    final dev = pickInput(inputs, _prefs.input);
    if (dev == null) {
      if (_prefs.input == null && boardOnUsb()) {
        _boardSince ??= t;
        // Windows needs a moment to add the audio endpoint after the board appears
        final settled = t.difference(_boardSince!) > const Duration(seconds: 6) && _devicesAt.isAfter(_boardSince!.add(const Duration(seconds: 5)));
        if (settled) {
          _setState(ThroughState.noUsbAudio);
          return;
        }
      } else {
        _boardSince = null;
      }
      _setState(_everRan || _prefs.input != null ? ThroughState.missing : ThroughState.searching);
      return;
    }
    _boardSince = null;
    if (st.micPermission == Mic.denied || st.micPermission == Mic.restricted) {
      _setState(ThroughState.denied);
      return;
    }
    final c = _config(dev.name);
    if (c != _sent || !applied) {
      if (c != _sent) _send(c, t);
      _setState(ThroughState.starting);
      return;
    }
    // same request, failed or lost: again once the device is listed after the trouble (a
    // replug), or every 3 s when it is there but would not open
    final listedSince = _devicesAt.isAfter(_troubleAt);
    final busy = st.capture == DevState.failed && st.captureError == AudioErr.openCapture;
    final permission = st.capture == DevState.failed && st.captureError == AudioErr.permission;
    if (_wantResend &&
        ((busy && t.difference(_sentAt) > const Duration(seconds: 3)) ||
            (permission && st.micPermission == Mic.authorized) ||
            (!busy && !permission && listedSince && t.difference(_sentAt) > const Duration(milliseconds: 800)))) {
      _send(c, t);
      _setState(ThroughState.starting);
      return;
    }
    if (busy) {
      _setState(ThroughState.failed);
    } else if (permission) {
      // state set above
    } else if (st.capture == DevState.lost || st.captureError == AudioErr.notFound) {
      _setState(ThroughState.missing);
    } else if (st.capture == DevState.failed) {
      _setState(ThroughState.failed);
    } else {
      _setState(ThroughState.starting);
    }
  }

  /// With the input running: follow output choices, retry an output that failed or went away.
  void _keepOutput(DateTime t) {
    final c = _config(_sent.input);
    if (c != _sent) {
      _send(c, t);
      return;
    }
    if (_prefs.through && (st.playback == DevState.failed || st.playback == DevState.lost)) {
      if (t.difference(_sentAt) > const Duration(seconds: 2)) _send(c, t);
    }
  }

  void _recordTick(DateTime t) {
    final b = backend!;
    final running = st.capture == DevState.running && st.configGen - _gen >= 0;
    if (_recWanted && !recording && running) {
      final path = _newRecordingPath();
      _recWanted = false;
      if (path == null) {
        recordNote = 'No folder to record into.';
        _notify();
        return;
      }
      b.recordStart(path);
      recordingPath = path;
      _recAskedAt = t;
      _recSeenOn = false;
      _recStopping = false;
      _log('audio: recording to $path');
      _notify();
      return;
    }
    final path = recordingPath;
    if (path == null) return;
    if (st.record == RecState.on) {
      _recSeenOn = true;
      return;
    }
    // stopped (asked, or by itself), or never started
    if (!_recSeenOn && !_recStopping && t.difference(_recAskedAt) < const Duration(seconds: 2)) return;
    recordingPath = null;
    _recStopping = false;
    if (st.recordFrames > 0) lastRecording = path;
    if (st.record == RecState.stopped && st.recordError != AudioErr.ok) {
      recordNote = st.recordError == AudioErr.lost
          ? 'The recording stopped: the Striso’s audio went away.'
          : 'The recording stopped: ${AudioErr.text(st.recordError)}.';
    } else if (!_recSeenOn) {
      recordNote = 'The recording did not start.';
    }
    _log('audio: recording ended (${st.recordFrames} frames${st.recordError != 0 ? ', ${AudioErr.text(st.recordError)}' : ''})');
    _notify();
  }

  String? _newRecordingPath() {
    final dir = recordingsDir?.call() ?? _defaultDir();
    if (dir == null) return null;
    try {
      Directory(dir).createSync(recursive: true);
    } catch (e) {
      _log('audio: cannot create $dir: $e');
      return null;
    }
    final sep = Platform.pathSeparator;
    final base = recordingName(_now());
    var p = '$dir$sep$base';
    for (var i = 2; File(p).existsSync() && i < 100; i++) {
      p = '$dir$sep${base.substring(0, base.length - 4)} ($i).wav';
    }
    return p;
  }

  String? _defaultDir() {
    final docs = backend?.documentsDir() ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return docs == null ? null : '$docs${Platform.pathSeparator}Striso Live Recordings';
  }

  // ---------------------------------------------------------------------------------- words

  void _setState(ThroughState s, {String? msg}) {
    final changed = s != state || (msg != null && msg != message);
    state = s;
    if (msg != null) message = msg;
    if (changed) {
      if (msg == null) _describe(false);
      _notify();
    }
  }

  static String bitsText(int b) => switch (b) {
    16 => '16-bit',
    24 => '24-bit',
    32 => '32-bit',
    -32 => 'float',
    _ => '',
  };

  /// MA_BUSY: another program holds the device.
  static const _maBusy = -17;

  void _describe(bool applied) {
    String m;
    Tone tn;
    String? out, hint;
    final custom = _prefs.input;
    switch (state) {
      case ThroughState.unavailable:
        m = backend == null ? 'The audio engine is missing from this build.' : 'The computer’s audio system did not start.';
        tn = Tone.problem;
      case ThroughState.off:
        m = 'Off. Turn on Through PC to hear the Striso on this computer.';
        tn = Tone.quiet;
      case ThroughState.searching:
        m = boardOnUsb() || !_haveDevices ? 'Looking for the Striso’s audio input…' : 'Looking for the Striso’s audio input: plug in the Striso.';
        tn = Tone.busy;
      case ThroughState.noUsbAudio:
        m = 'This Striso’s firmware has no USB audio: update the firmware to hear it through the computer.';
        tn = Tone.quiet;
      case ThroughState.missing:
        m = custom != null
            ? '“$custom” is not connected.'
            : 'The Striso’s audio input is gone (unplugged or restarting). It comes back by itself.';
        tn = Tone.problem;
      case ThroughState.permission:
        m = 'macOS is asking whether Striso Live may use the Striso’s audio input.';
        tn = Tone.busy;
      case ThroughState.denied:
        m = 'macOS does not let Striso Live use audio input: allow it in System Settings › Privacy & Security › Microphone.';
        tn = Tone.problem;
      case ThroughState.starting:
        m = 'Opening the Striso’s audio input…';
        tn = Tone.busy;
      case ThroughState.failed:
        m = 'The Striso’s audio input would not open (error ${st.captureResult}). Trying again.';
        tn = Tone.problem;
      case ThroughState.running:
        final fmt = [
          if (st.captureRate > 0) '${(st.captureRate / 1000).toStringAsFixed(st.captureRate % 1000 == 0 ? 0 : 1)} kHz',
          if (bitsText(st.captureBits).isNotEmpty) bitsText(st.captureBits),
          if (st.captureExclusive) 'exclusive',
        ].join(' · ');
        if (_prefs.through) {
          m = 'Playing through the computer · $fmt';
          tn = st.playback == DevState.running ? Tone.ok : Tone.busy;
          if (st.playback == DevState.failed || st.playback == DevState.lost) {
            out = st.playback == DevState.lost ? 'The output went away: trying again.' : 'The output would not open: trying again.';
            tn = Tone.problem;
          }
          if (st.playback == DevState.running && _sent.exclusiveOutput && !st.playbackExclusive) {
            hint = st.playbackExclResult == _maBusy
                ? 'Shared output: another program holds it exclusively.'
                : 'Shared output: it would not open exclusively.';
          }
        } else {
          m = 'Listening to the input (Through PC is off) · $fmt';
          tn = Tone.ok;
        }
        final o = _prefs.output;
        if (_prefs.through && o != null && _haveDevices && !outputs.any((d) => d.name == o)) {
          out ??= '“$o” is not connected: playing to the default output.';
        }
    }
    if (_prefs.through && outputBluetooth) hint = 'Bluetooth adds ~150–250 ms. Use a wired output for playing.';
    outputNote = out;
    final changed = m != message || tn != tone || hint != outputHint;
    message = m;
    tone = tn;
    outputHint = hint;
    if (changed) {
      if (m != _lastLogged && state != ThroughState.running && state != ThroughState.off) {
        _lastLogged = m;
        _log('audio: $m');
      }
      if (hint != null && hint.startsWith('Shared')) _log('audio: $hint');
      _notify();
    }
  }

  /// The live numbers for the meters' 20 Hz rebuild (not in [message]): latency, dropouts.
  String get liveLine {
    if (state != ThroughState.running) return '';
    final parts = <String>[];
    if (_prefs.through && st.playback == DevState.running) {
      final d = dropoutsLastMinute().values.fold(0, (a, b) => a + b);
      parts.add(d == 0 ? 'no dropouts in the last minute' : 'dropouts: $d in the last minute');
      if (st.playbackExclusive) parts.add('exclusive output');
    }
    if (st.recordDropped > 0) parts.add('${st.recordDropped} frames lost in the recording');
    return parts.join(' · ');
  }

  void _log(String s) => log?.call(s);
}
