// Where the sound goes in each session state (docs/architecture.md, Sound and routing):
//   Live(Striso)                 the Striso's USB audio input (Through PC as the user chose, Record)
//   Virtual (connecting to live) the output alone, the virtual board rendering in its callback;
//                                the chosen MIDI inputs into the board's own USB-MIDI input
//   anything else                nothing open
// The virtual board's clock never depends on the output: it renders in the output's callback
// while the output runs, and on its own real-time thread whenever it does not (the status then
// says "No sound: ...").

import 'dart:async';

import 'package:striso_audio/striso_audio.dart';

import '../virtual_support.dart';
import 'resources.dart';
import 'session_machine.dart';

class SoundRouting {
  final ThroughPc audio;
  final Resources resources;
  final MidiInputs? midi;
  final void Function(String) log;

  /// How often the clock is checked, and how long the board may stand still in the output's
  /// callback before it gets its own clock back.
  final Duration every, stall;

  VirtualSound? _v;
  Timer? _clock;
  int _lastFrames = 0;
  DateTime _lastMove = DateTime(0), _retryAt = DateTime(0);
  String? _silent; // why there is no sound (the virtual board on its own clock)
  bool _midiOn = false;
  final DateTime Function() _now;

  SoundRouting({
    required this.audio,
    required this.resources,
    this.midi,
    required this.log,
    this.every = const Duration(milliseconds: 100),
    this.stall = const Duration(milliseconds: 300),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Why the virtual board makes no sound now (null: it plays, or there is none).
  String? get silentWhy => _v == null ? null : (_silent ?? (audio.playing ? null : _waitingWhy));

  String get _waitingWhy {
    if (audio.backend == null) return 'audio is off in this run';
    if (audio.state == ThroughState.unavailable) return 'the computer’s audio system did not start';
    return audio.outputNote ?? 'opening the output…';
  }

  /// The route for [s] with the instrument [v] (null when none runs).
  static AudioRoute routeFor(SessionState s) {
    final m = s.mode;
    if (m == Mode.virtual && (s is Connecting || s is Live || s is Rebooting)) return AudioRoute.source;
    if (m == Mode.striso && s is Live) return AudioRoute.input;
    return AudioRoute.off;
  }

  /// Follows the session: call on every change of the state or the instrument.
  void apply(SessionState s, VirtualSound? v) {
    final r = routeFor(s);
    if (r != AudioRoute.source) v = null;
    if (!identical(v, _v)) _swap(v);
    audio.setRoute(r);
    // MIDI inputs open while Virtual is live (into the board's own USB-MIDI input; the Dart mock
    // of the widget tests has none: the inputs still open, their bytes go nowhere)
    final midiWanted = r == AudioRoute.source && s is Live;
    if (midiWanted != _midiOn) {
      _midiOn = midiWanted;
      final m = midi;
      if (m != null) {
        if (midiWanted) {
          if (v != null) m.setSink(v.midiFn, v.midiUser);
          m.start();
        } else {
          m.stop();
          m.setSink(0, 0);
        }
      }
    }
    _resources();
  }

  void _swap(VirtualSound? v) {
    final old = _v;
    _v = null;
    _clock?.cancel();
    _clock = null;
    if (old != null) {
      // the callback leaves the old board before this returns; it keeps its own clock meanwhile
      audio.setSource(0, 0);
      if (old.alive) old.startRealtime();
      if (_midiOn) {
        midi?.setSink(0, 0);
      }
    }
    _silent = null;
    if (v == null) return;
    _v = v;
    v.startRealtime(); // until the output runs
    if (!audio.setSource(v.sourceFn, v.sourceUser)) {
      _silent = audio.backend == null ? 'audio is off in this run' : 'the audio engine cannot play the virtual Striso';
    }
    if (_midiOn) midi?.setSink(v.midiFn, v.midiUser);
    _lastFrames = v.timeFrames;
    _lastMove = _now();
    _clock = Timer.periodic(every, (_) => checkClock());
  }

  /// The board's clock: the output's callback while the output plays, else its own thread.
  void checkClock() {
    final v = _v;
    if (v == null || !v.alive) return;
    final t = _now();
    final f = v.timeFrames;
    if (f != _lastFrames) {
      _lastFrames = f;
      _lastMove = t;
    }
    if (v.realtime) {
      if (audio.playing && !t.isBefore(_retryAt) && _silent == null) {
        v.stopRealtime(); // the output renders it from now on
        _lastMove = t;
        log('virtual sound: the output plays the virtual board');
        _resources();
      }
    } else if (t.difference(_lastMove) > stall) {
      v.startRealtime(); // never a stopped board
      _retryAt = t.add(const Duration(seconds: 3));
      log('virtual sound: the output stopped rendering the board; it runs on its own clock (no sound)');
      _resources();
    }
  }

  /// The board renders in the output's callback (it is heard).
  bool get heard => _v != null && !_v!.realtime;

  void _resources() {
    final st = audio.st;
    resources.set(Res.audioOutput, audio.devicesOpen && st.playback == DevState.running, audio.outputDevice?.name ?? 'default output');
    resources.set(Res.audioInput, audio.devicesOpen && st.capture == DevState.running, 'the Striso’s USB audio');
    resources.set(Res.audioEngine, audio.devicesOpen || audio.ticking, audio.route.name);
    resources.set(Res.virtualBoard, _v != null, _v == null ? '' : (heard ? 'in the output’s callback' : 'on its own clock'));
    resources.set(Res.midi, _midiOn, 'inputs');
  }

  /// The audio engine reported something (its listener): keep the resources true.
  void audioChanged() => _resources();

  void dispose() {
    _clock?.cancel();
    _clock = null;
    if (_v != null) audio.setSource(0, 0);
    _v = null;
    if (_midiOn) {
      midi?.stop();
      midi?.setSink(0, 0);
      _midiOn = false;
    }
  }
}
