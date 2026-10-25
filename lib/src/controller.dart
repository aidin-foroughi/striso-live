// Striso Live's state and behaviour: connection (with the reconnect rules), voices, parameters
// with undo, mutate and morph, user presets, synth load, key and harmony, the key equalizer,
// saving touch settings to the board, the settings overlay and the console. The widgets only
// show this and call into it. Port of tools/app/js/app.js.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart' show LoadFailure, LoadFailureKind, StrisoVirtualLib, svApiVersion;

import 'app_log.dart';
import 'firmware_library.dart';
import 'harmony_tracker.dart';
import 'morph_model.dart';
import 'params_model.dart';
import 'store.dart';
import 'session/board.dart';
import 'session/resources.dart';
import 'session/session.dart';
import 'session/session_machine.dart';
import 'session/sound_routing.dart';
import 'virtual_support.dart';

export 'params_model.dart' show ParamSet, allTargets, targetNames;
export 'session/session.dart' show UsbBackend, reconnectDelay;
export 'session/session_machine.dart' show Mode, SessionState, Idle, Waiting, Connecting, Live, Rebooting, Failed, FailKind, IdleWhy;

/// Milliseconds since the app started: the one clock for the live state and the animation.
final Stopwatch _appClock = Stopwatch()..start();
double clockMs() => _appClock.elapsedMicroseconds / 1000;

/// A change notifier anyone may ring.
class Pulse extends ChangeNotifier {
  void ping() => notifyListeners();
}

enum Dot { off, on, demo, busy }

/// A fix the user can click on a problem or the start screen (docs/flows.md 7).
enum Fix { connectStriso, connectNow, playVirtual, pickBuild, installBuild, openFolder, copyVersion, getRuntime, clearQuarantine }

extension FixLabel on Fix {
  String get label => switch (this) {
    Fix.connectStriso => 'Connect Striso',
    Fix.connectNow => 'Connect now',
    Fix.playVirtual => 'Play Virtual…',
    Fix.pickBuild => 'Pick a build…',
    Fix.installBuild => 'Install a release zip…',
    Fix.openFolder => 'Open the firmware folder',
    Fix.copyVersion => 'Copy version',
    Fix.getRuntime => 'Get the runtime',
    Fix.clearQuarantine => 'Clear quarantine',
  };
}

/// A problem of the session: a title, the sentence that says what to do, and the fixes. The
/// banner strip and the start screen render the same one.
class Problem {
  final String title, detail;
  final List<Fix> actions;
  const Problem(this.title, this.detail, this.actions);
}

/// The start screen over the dimmed board: a title, a sentence, the actions; [busy] is the
/// accent line while something is under way (connecting, saving).
class Invite {
  final String title, body;
  final List<Fix> actions;
  final String? busy;
  const Invite(this.title, this.body, this.actions, {this.busy});
}

/// A firmware build as the build menu lists it (docs/flows.md 5).
class BuildInfo {
  final FirmwareBuild build;
  final bool current, onStriso;

  /// The commit from the firmware version the library reports, if it was readable.
  final String? commit;

  /// Why it cannot be chosen (null: it loads).
  final String? reason;
  const BuildInfo(this.build, {required this.current, required this.onStriso, this.commit, this.reason});
  bool get loadable => reason == null;
  String get title => build.title;
  String get path => build.path;
}

/// What a probe of a build's library said, with the file's stamp it was true for.
class BuildProbe {
  final int stamp;
  final int? api;
  final String? firmwareVersion;
  final LoadFailure? failure;
  const BuildProbe(this.stamp, {this.api, this.firmwareVersion, this.failure});
}

/// "2026-10-25_v2.2.4-308-g3e05282_all" or "strisoboard_v2.2.4-308-g3e05282" -> "3e05282".
String? commitOf(String? v) => v == null ? null : RegExp(r'-g([0-9a-f]{7,})').firstMatch(v)?.group(1);

/// Key labels: spelled names (with or without the octave), degrees, solfège, the pitch as the
/// board plays it in quarter-tone notation, its cents from 12-TET, or none.
enum Names { octave, letters, degrees, solfege, pitch, cents, off }

/// Key colouring by tonal function (rims only; the pressure fill stays the hero).
enum KeyColour { off, degree, function, chord }

/// What pitch labels are measured against: A = 440 Hz (the board's D is exact), or the key's root.
enum PitchRef { absolute, root }

enum AppTab { play, sound, setup }

class EngineButton {
  final String engine;
  final int color; // 0xRRGGBB, the led colour of its voice key
  final int count;
  const EngineButton(this.engine, this.color, this.count);
}

/// 0xRRGGBB of a hue at the engine-stripe saturation and lightness.
class HSLColorInt {
  static int of(double hue) {
    final c = (1 - (2 * 0.55 - 1).abs()) * 0.6, x = c * (1 - ((hue / 60) % 2 - 1).abs()), m = 0.55 - c / 2;
    final (r, g, b) = hue < 60
        ? (c, x, 0.0)
        : hue < 120
        ? (x, c, 0.0)
        : hue < 180
        ? (0.0, c, x)
        : hue < 240
        ? (0.0, x, c)
        : hue < 300
        ? (x, 0.0, c)
        : (c, 0.0, x);
    int v(double f) => ((f + m) * 255).round().clamp(0, 255);
    return (v(r) << 16) | (v(g) << 8) | v(b);
  }
}

class EngineInfo {
  final String label, blurb;
  final double hue;
  const EngineInfo(this.label, this.blurb, this.hue);
}

const _engineInfo = {
  'strisy': EngineInfo('Strisy', 'the original synth', 44),
  'va': EngineInfo('Virtual analog', 'saws, sync, ladder filter', 18),
  'modal': EngineInfo('Modal', 'bars, bells, glass', 190),
  'bowed': EngineInfo('Bowed', 'bowed string', 340),
  'reed': EngineInfo('Reed', 'blown reed', 100),
  'wind': EngineInfo('Wind', 'clarinets, saxes, flute', 130),
  'brass': EngineInfo('Brass', 'trumpet to tuba', 32),
  'trumpet': EngineInfo('Trumpet', 'physical model, valves and mutes', 180),
  'ep': EngineInfo('Electric piano', 'tines and reeds', 260),
  'epiano': EngineInfo('Electric piano', 'tines and reeds', 260),
  'sine': EngineInfo('Sine', 'test voice', 220),
};

EngineInfo engineInfo(String e, [int k = 0]) =>
    _engineInfo[e] ?? EngineInfo(e.isEmpty ? e : e[0].toUpperCase() + e.substring(1), '', ((k * 67 + 30) % 360).toDouble());

class ToastMsg {
  final int id;
  final String text, kind; // '' | 'warn' | 'error'
  final String? action;
  final VoidCallback? onAction;
  const ToastMsg(this.id, this.text, this.kind, {this.action, this.onAction});
}

enum SetupMode { sensitivity, equalizer, settings }

class Banner {
  final String text;
  final bool info;
  const Banner(this.text, {this.info = false});
}

class SaveStatus {
  final String text, cls; // '' | 'ok' | 'err'
  const SaveStatus(this.text, [this.cls = '']);
}

/// Per-engine voice state for the settings overlay.
class SettingsVoice {
  final int count;
  final bool current;
  final String preset;
  final List<VoiceEntry> list;
  const SettingsVoice(this.count, this.current, this.preset, this.list);
}

class AppOptions {
  final bool demo, noUsb, noAudio;
  final String? fakeSave; // null, 'ok' or 'fail'
  final bool reducedMotion;

  /// Virtual: a firmware build's striso_virtual (--virtual-lib=PATH, else STRISO_VIRTUAL_LIB or
  /// the one found); --mock-demo: the Dart mock instead.
  final String? virtualLib;
  final bool mockDemo;
  const AppOptions({
    this.demo = false,
    this.noUsb = false,
    this.noAudio = false,
    this.fakeSave,
    this.reducedMotion = false,
    this.virtualLib,
    this.mockDemo = false,
  });

  static AppOptions parse(List<String> args) {
    String? fake, vlib;
    for (final a in args) {
      if (a == '--fake-save') fake = 'ok';
      if (a.startsWith('--fake-save=')) fake = a.substring(12);
      if (a.startsWith('--virtual-lib=')) vlib = a.substring(14);
    }
    return AppOptions(
      demo: args.contains('--demo'),
      noUsb: args.contains('--no-usb'),
      noAudio: args.contains('--no-audio'),
      fakeSave: fake,
      reducedMotion: args.contains('--reduced-motion'),
      virtualLib: vlib,
      mockDemo: args.contains('--mock-demo'),
    );
  }
}

class AppController extends ChangeNotifier implements MorphHost, SessionHost, ParamsHost {
  final AppOptions options;
  final Store store;
  final UsbBackend? usb;
  final String backupDir;

  /// The audio engine: Through PC and Record in Striso mode, the virtual Striso's output in
  /// Virtual. What it opens is the session's decision (SoundRouting), never a toggle's alone.
  late final ThroughPc audio;

  /// Through PC's state and choices changed (toggle, status line, pickers).
  final audioState = Pulse();

  /// About 20 times a second while audio runs: levels, latency, the recording's time.
  final audioLevels = Pulse();

  final live = LiveState();

  /// The live parameters with undo, A/B, Mutate (params_model.dart).
  late final ParamsModel sound = ParamsModel(this, clock: clockMs);
  History get history => sound.history;
  Map<int, ParamSet> get params => sound.params;
  Map<int, Set<String>> get locks => sound.locks;
  bool get abOn => sound.abOn;
  bool get edited => sound.edited;
  bool get hasSound => sound.hasSound;
  String get mutateScope => sound.mutateScope;
  double get mutateAmount => sound.mutateAmount;
  set mutateAmount(double v) => sound.mutateAmount = v;
  Param? findParam(int t, String name) => sound.findParam(t, name);
  bool setValue(int t, Param p, double v, {bool record = true, bool send = true}) => sound.setValue(t, p, v, record: record, send: send);
  void onEdit(int t, Param p, double v, String phase, [String? label, String? key]) => sound.onEdit(t, p, v, phase, label, key);
  void undo() => sound.undo();
  void redo() => sound.redo();
  void setMutateScope(String s) => sound.setMutateScope(s);
  void mutate() => sound.mutate();
  void resetAll() => sound.resetAll();
  void toggleLock(int t, Param p) => sound.toggleLock(t, p);
  void setAB(bool on) => sound.setAB(on);
  Future<void> readBack(List<int> targets) => sound.readBack(targets);
  void _flushValues() => sound.flush();

  // ParamsHost
  @override
  void valuesChanged() => values.ping();
  @override
  void stateChanged() => notifyListeners();
  @override
  void editedByUser() {
    _rememberEditsSoon();
    _confirmSoon();
  }

  Timer? _confirmTimer;

  /// The values just sent show as pending until the board reads them back: after the gesture
  /// (the state poll does it when the board's counter moves; this makes sure it happens).
  void _confirmSoon() {
    _confirmTimer?.cancel();
    _confirmTimer = Timer(const Duration(milliseconds: 500), () {
      _confirmTimer = null;
      if (_disposed || !canSend || !sound.anyPending) return;
      if (clockMs() - sound.editT < 400) {
        _confirmSoon(); // still moving
        return;
      }
      unawaited(readBack(sound.pendingTargets));
    });
  }
  late final harmony = HarmonyTracker(live);
  late final morph = MorphModel(this);

  /// Parameter values changed (knobs, sliders, readouts).
  final values = Pulse();

  /// 120 ms readouts: stats, probe, diagnostics, live meter text.
  final stats = Pulse();

  final toasts = ValueNotifier<List<ToastMsg>>(const []);

  /// The connection: its state machine, the board, the pollers (session/session.dart).
  late final Session session;

  /// The audio route, the virtual board's clock, MIDI into the virtual Striso.
  late final SoundRouting routing;

  /// MIDI inputs for the virtual Striso (null without the native library).
  MidiInputs? midi;

  /// The virtual Striso (the striso_virtual library chosen, or the Dart mock in widget tests).
  late final VirtualStrisoRuntime virtual;

  bool saving = false, listsLoading = false;
  VersionInfo? version;

  /// What every key does with Settings held, as the board lists it (StcX).
  SettingsLayout settingsLayout = SettingsLayout.empty;

  /// The current voice's hero knobs as the board names them (StcH).
  HeroKnobs? heroes;

  /// The board's state as it last reported it (StcY), and its change counter (Stcy).
  BoardState? boardState;
  int? _stateCount;
  bool _stateBusy = false;
  Banner? banner;
  Future<void>? listsReady;
  Map<String, int>? trace;
  Stopwatch? _traceClock;

  // voices and parameters
  List<VoiceEntry> voices = const [];
  int current = -1;
  String voiceName = '';
  Future<void> _voiceBusy = Future.value();
  String? lastSound;

  // load
  final loadHist = <LoadReading>[];
  LoadReading? load;
  int _loadMisses = 0;
  bool loadNa = false;

  // view state
  Names names = Names.octave;
  KeyColour colour = KeyColour.off;
  PitchRef pitchRef = PitchRef.absolute;
  int keyRoot = 0;
  String keyScale = 'off';
  MusicKey? currentKey;
  bool settingsOn = false;
  int settingsSelected = -1;
  int hover = -1, hoverControl = -1;
  double waveT = -1e9;

  // key equalizer
  bool eqOn = false, eqFollow = true;
  int eqSelected = -1;
  double eqSinceT = 0;
  double? eqMedian;

  SaveStatus saveStatus = const SaveStatus('');

  // presets and morph corners
  List<Preset> presets = [];
  Map<String, Object?> _morphStore = {};

  bool _disposed = false;
  int _toastId = 0;

  AppController({required this.options, required this.store, this.usb, AudioBackend? audioBackend, String? backupDir, MidiBackend? midiBackend})
    : backupDir = backupDir ?? '${appSupportDir()}${Platform.pathSeparator}backups' {
    _loadPrefs();
    final audioJson = store.raw('audio');
    final repaired = AudioPrefs.repairNote(audioJson);
    audio = ThroughPc(
      backend: audioBackend,
      prefs: AudioPrefs.fromJson(audioJson),
      boardOnUsb: () => (client != null && mode == Mode.striso) || session.lastPresent == true,
      onPrefs: (p) => store.set('audio', p.toJson()),
      log: (s) => log(s),
      route: AudioRoute.off,
    );
    if (repaired != null) {
      log(repaired);
      store.set('audio', audio.prefs.toJson()); // once: saved as version 3
    }
    final mb = midiBackend ?? (audioBackend is NativeAudioBackend ? NativeMidiBackend.of(audioBackend.library) : null);
    if (mb != null) {
      midi = MidiInputs.fromJson(mb, store.raw('midi'), onPrefs: (j) => store.set('midi', j), log: (s) => log(s));
      midi!.addListener(audioState.ping);
    }
    final dataDir = store.path == null ? null : File(store.path!).parent.path;
    firmwareDir = dataDir == null ? null : '$dataDir${Platform.pathSeparator}firmware';
    final chosen = store.get<String>('virtualLib');
    final libPath =
        options.virtualLib ??
        (chosen != null && File(chosen).existsSync() ? chosen : null) ??
        Platform.environment['STRISO_VIRTUAL_LIB'] ??
        findFirmwareBuilds(firmwareDir).firstOrNull?.path;
    virtual = VirtualStrisoRuntime(
      libPath: libPath,
      title: libPath == null ? null : buildOf(libPath).title,
      mockOnly: options.mockDemo,
      flashFile: dataDir == null ? null : '$dataDir${Platform.pathSeparator}virtual${Platform.pathSeparator}flash.bin',
      log: (s) => log(s),
      onChanged: () => _route(),
    );
    session = Session(host: this, store: store, usb: options.noUsb ? null : usb, virtual: virtual);
    routing = SoundRouting(audio: audio, resources: session.resources, midi: midi, log: (s) => log(s));
    audio.addListener(() {
      routing.audioChanged();
      audioState.ping();
    });
    audio.addLevelListener(audioLevels.ping);
    live.pressListeners.add((id, _) {
      if (eqFollow) eqSelect(id);
    });
    live.releaseListeners.add((_, _) => values.ping());
  }

  // ---------------------------------------------------------------------------------------------
  // lifecycle

  void _loadPrefs() {
    final n = store.get<String>('names');
    names = Names.values.firstWhere((x) => x.name == n, orElse: () => Names.octave);
    colour = KeyColour.values.firstWhere((x) => x.name == store.get<String>('colour'), orElse: () => KeyColour.off);
    pitchRef = PitchRef.values.firstWhere((x) => x.name == store.get<String>('pitchRef'), orElse: () => PitchRef.absolute);
    final k = store.raw('key');
    if (k is Map) {
      keyRoot = (k['root'] as num?)?.toInt() ?? 0;
      keyScale = (k['scale'] as String?) ?? 'off';
      if (!scales.containsKey(keyScale)) keyScale = 'off';
    } else if (options.demo) {
      keyScale = 'major';
    }
    currentKey = makeKey(keyRoot, keyScale);
    harmony.key = currentKey;
    final eq = store.raw('eq');
    if (eq is Map) {
      eqOn = eq['on'] == true;
      eqFollow = eq['follow'] != false;
    }
    settingsOn = store.get<bool>('settingsOverlay') ?? false;
    tab = AppTab.values.firstWhere((t) => t.name == store.get<String>('tab'), orElse: () => AppTab.play);
    morphOpen = store.get<bool>('morphOpen') ?? false;
    final ps = store.raw('presets');
    if (ps is List) {
      final r = parsePresetFile(jsonEncode(ps));
      presets = r.presets;
    }
    final ms = store.raw('morph');
    if (ms is Map) _morphStore = ms.cast<String, Object?>();
  }

  String? get intent => session.intent;

  /// At start: what the user left on (the Striso connected, or Virtual), else nothing.
  Future<void> start() async {
    audio.start();
    await session.start(virtualFirst: options.demo);
  }

  @override
  void dispose() {
    _disposed = true;
    _confirmTimer?.cancel();
    _editsTimer?.cancel();
    routing.dispose();
    unawaited(session.dispose());
    midi?.dispose();
    audio.dispose();
    unawaited(usb?.dispose());
    super.dispose();
  }

  /// Let go of everything before the window closes.
  Future<void> shutdown() async {
    try {
      await session.disconnect(why: IdleWhy.start).timeout(const Duration(seconds: 3));
    } catch (_) {}
    routing.dispose();
    midi?.dispose();
    audio.dispose(); // finishes a recording's file, closes the audio devices
    await usb?.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // status, banner, toasts, log

  void log(String text, [LogKind kind = LogKind.info]) => appLog.add(text, kind);
  void logKind(String text, LogKind kind) => appLog.add(text, kind);

  @override
  void note(String text, {bool error = false}) => log(text, error ? LogKind.err : LogKind.info);

  void showBanner(String text, {bool info = false}) {
    banner = Banner(text, info: info);
    appLog.add(text, LogKind.err);
    notifyListeners();
  }

  void hideBanner() {
    if (banner == null) return;
    banner = null;
    notifyListeners();
  }

  @override
  void toast(String text, [String kind = '']) => _toast(text, kind);

  void toastAction(String text, String action, VoidCallback onAction) => _toast(text, '', action: action, onAction: onAction);

  void _toast(String text, String kind, {String? action, VoidCallback? onAction}) {
    final t = ToastMsg(++_toastId, text, kind, action: action, onAction: onAction);
    var l = [...toasts.value, t];
    if (l.length > 4) l = l.sublist(l.length - 4);
    toasts.value = l;
    Timer(Duration(milliseconds: kind == 'error' || action != null ? 6000 : 2600), () => dismissToast(t.id));
  }

  void dismissToast(int id) {
    if (_disposed) return;
    toasts.value = toasts.value.where((x) => x.id != id).toList();
  }

  void _trace(String label, {bool start = false}) {
    if (start || _traceClock == null) {
      _traceClock = Stopwatch()..start();
      trace = {};
    }
    final ms = _traceClock!.elapsedMilliseconds;
    trace![label] = ms;
    log('connect +$ms ms: $label');
  }

  // ---------------------------------------------------------------------------------------------
  // the session: state, status, connect, disconnect (the logic is in session/session.dart; what
  // the user sees of it is docs/flows.md)

  SessionState get state => session.state;

  /// The mode of the session (connecting, live, rebooting, failed), or null when idle.
  Mode? get mode => session.mode;
  bool get isVirtual => mode == Mode.virtual;

  /// The instrument that plays (or is starting, or restarts): what the header's control fills.
  /// Null when nothing does, a failed one included.
  Mode? get playing => switch (state) {
    Connecting(:final mode) || Live(:final mode) || Rebooting(:final mode) => mode,
    _ => null,
  };

  /// The console of the active board.
  @override
  StrisoClient? get client => session.client;

  bool get connecting => state is Connecting;
  bool get reconnectPending => state is Waiting;

  /// A session is up (the UI shows the board's things).
  bool get connected => client != null && (state is Live || state is Connecting);

  /// The app may send to the board: the session is live. Every control that acts on the board
  /// checks this; without it they do nothing and say so.
  bool get canSend => client != null && state is Live;

  /// What a control that sends to the board says while it cannot.
  String get sendHint => connecting ? 'Connecting…' : 'Connect to switch this from the app';

  /// A Striso is on USB (from the last probe).
  bool get boardPresent => session.lastPresent == true;

  /// The connection was lost (unplugged or a USB error), not ended by the user.
  bool get lost => state is Idle && (state as Idle).lost;
  bool get ledOn => connected;

  /// The Striso's firmware as it reported it the last time it was connected in this run (the
  /// build list marks the build that matches it; a too-old Striso's problem names it).
  VersionInfo? strisoVersion;

  /// The status dot, from the state.
  Dot get dot => switch (state) {
    Live(mode: Mode.virtual) => Dot.demo,
    Live() => Dot.on,
    Connecting() || Waiting() || Rebooting() => Dot.busy,
    Failed(kind: FailKind.busy) => Dot.busy,
    _ => Dot.off,
  };

  /// The status in a few words, from the state (docs/flows.md 3).
  String get status {
    final s = state;
    return switch (s) {
      Idle(why: IdleWhy.unplugged) => 'Unplugged',
      Idle(why: IdleWhy.lost) => 'Connection lost',
      Idle(why: IdleWhy.user) => 'Disconnected',
      Idle(why: IdleWhy.stopped) => 'Stopped',
      Idle(why: IdleWhy.modeSwitch) => 'Switching…',
      Idle() => boardPresent ? 'Striso found' : 'Not connected',
      Waiting(:final why) when why.startsWith('Board busy') => 'Striso busy · trying again',
      Waiting() => 'Striso found · connecting in ${reconnectDelay.inSeconds} s',
      Connecting(mode: Mode.virtual) => 'Starting Virtual…',
      Connecting(mode: Mode.striso) => 'Connecting…',
      Live(mode: Mode.striso) => listsLoading ? 'Connected · reading parameters' : 'Connected',
      Live(mode: Mode.virtual) => virtual.label,
      Rebooting(mode: Mode.virtual, why: 'reset') => 'Virtual restarts…',
      Rebooting() => 'Saving to the Striso…',
      Failed() => problem?.title ?? 'Not connected',
    };
  }

  /// The sound line: what makes the sound and where it is heard.
  String get soundLine {
    final s = state;
    if (s.mode == Mode.virtual && s is! Failed) {
      final out = audio.outputDevice?.name ?? 'the default output';
      final why = routing.silentWhy;
      final input = _inputLine();
      return why != null ? '${virtual.label} · No sound: $why$input' : '${virtual.label} → $out$input';
    }
    if (s is Live && s.mode == Mode.striso) {
      if (!audio.through) return 'Striso · heard from its jack';
      final out = audio.outputDevice?.name ?? 'the default output';
      return audio.playing ? 'Striso · Through PC → $out' : 'Striso · Through PC: ${audio.message}';
    }
    return '';
  }

  /// The header's one line: the sound line while a session plays, else the status.
  String get statusLine {
    final l = soundLine;
    return l.isNotEmpty && (state is Live) ? l : status;
  }

  String _inputLine() {
    final m = midi;
    if (m == null) return ' · input: on-screen';
    final open = [
      for (final d in m.devices)
        if (d.state == MidiInputState.open) d.midi2 ? '${d.name} (MIDI 2.0)' : d.name,
    ];
    return open.isEmpty ? ' · input: on-screen' : ' · input: ${open.join(', ')}';
  }

  // the start screen and the problems ------------------------------------------------------------

  /// The start screen over the dimmed board (docs/flows.md 4 and 7): null while a session is up.
  Invite? get invite {
    final s = state;
    if (connected) return null;
    final p = problem;
    if (p != null) return Invite(p.title, p.detail, p.actions);
    return switch (s) {
      Idle(why: IdleWhy.user) => const Invite('Disconnected', 'You let go of the Striso.', [Fix.connectStriso, Fix.playVirtual]),
      Idle(why: IdleWhy.stopped) => const Invite('Stopped', 'Nothing plays.', [Fix.connectStriso, Fix.playVirtual]),
      Idle(why: IdleWhy.unplugged) => const Invite('Striso unplugged', 'It reconnects by itself a few seconds after it is back.', [Fix.playVirtual]),
      Idle(why: IdleWhy.lost, :final note) => Invite('Connection lost', note ?? '', const [Fix.connectStriso, Fix.playVirtual]),
      Idle(why: IdleWhy.modeSwitch) => const Invite('', '', [], busy: 'Switching…'),
      Idle() when boardPresent => const Invite('Striso found', '', [], busy: 'Connecting…'),
      Idle() => const Invite(
        'Plug in your Striso',
        'It connects by itself. Or play Virtual: the Striso firmware on this computer.',
        [Fix.playVirtual],
      ),
      Waiting(:final why) when why.startsWith('Board busy') => const Invite(
        'Your Striso is busy',
        'Another program holds it: trying again.',
        [Fix.playVirtual],
        busy: 'Trying again…',
      ),
      Waiting() => Invite('Striso found', '', const [Fix.connectNow, Fix.playVirtual], busy: 'Connecting in ${reconnectDelay.inSeconds} s…'),
      Connecting(mode: Mode.striso) => const Invite('', '', [], busy: 'Connecting to your Striso…'),
      Connecting(mode: Mode.virtual) => const Invite('', '', [], busy: 'Starting Virtual…'),
      Rebooting(mode: Mode.virtual, why: 'reset') => const Invite('', '', [], busy: 'Virtual restarts…'),
      Rebooting() => const Invite('', '', [], busy: 'Saving to the Striso…'),
      _ => null,
    };
  }

  /// The session's problem and its fix (docs/flows.md 7), while the state is Failed; else null.
  Problem? get problem {
    final s = state;
    if (s is! Failed) return null;
    final title = virtual.buildTitle ?? 'This build';
    switch (s.kind) {
      case FailKind.noUsb:
        return const Problem('USB is off in this run', 'The app was started with --no-usb.', [Fix.playVirtual]);
      case FailKind.notFound:
        if (s.message.startsWith('Saved')) {
          return const Problem('The Striso did not come back', 'Saved. Plug it in again, or connect it.', [Fix.connectStriso, Fix.playVirtual]);
        }
        return const Problem('No Striso on USB', 'Plug it in and switch it on; it connects by itself.', [Fix.playVirtual]);
      case FailKind.busy:
        return const Problem(
          'Your Striso is busy',
          'Another program holds it: striso.py, the web app, a flash tool. Close it, then connect.',
          [Fix.connectStriso, Fix.playVirtual],
        );
      case FailKind.noDriver:
        return Problem(
          'No driver for the Striso',
          Platform.isWindows
              ? 'Interface 2 needs the WinUSB driver. Zadig sets it: Options › List all devices, Striso (Interface 2), WinUSB.'
              : s.message,
          const [Fix.connectStriso],
        );
      case FailKind.needsUpdate:
        if (s.mode == Mode.virtual) {
          return Problem(
            '$title is too old for Striso Live',
            'It runs ${virtual.version ?? 'an old firmware'}; the app needs StcX, Stcy and StcH. Pick a newer build.',
            const [Fix.pickBuild],
          );
        }
        final fw = strisoVersion?.fw;
        return Problem(
          'This Striso needs a firmware update',
          fw == null
              ? 'Striso Live needs the current firmware, and this Striso did not say which it runs. Flash the latest release, then plug it in again.'
              : 'Striso Live needs the current firmware; this Striso runs $fw. Flash the latest release, then plug it in again.',
          [if (fw != null) Fix.copyVersion, Fix.playVirtual],
        );
      case FailKind.library:
        final f = virtual.failure;
        if (f == null) {
          if (virtual.libPath == null && buildList().isEmpty) {
            return const Problem('No firmware builds for Virtual', 'Install a release zip, or put a build in the firmware folder.', [
              Fix.installBuild,
              Fix.openFolder,
            ]);
          }
          return Problem('Virtual did not start', s.message, const [Fix.playVirtual, Fix.pickBuild]);
        }
        return switch (f.kind) {
          LoadFailureKind.apiMismatch => Problem(
            '$title was built for another Striso Live',
            'Its C API is ${f.api}; this app speaks $svApiVersion. Ask for a rebuild, or pick another build.',
            const [Fix.pickBuild, Fix.openFolder],
          ),
          LoadFailureKind.notLibrary => Problem('$title is not a striso_virtual library', f.message, const [Fix.pickBuild, Fix.openFolder]),
          LoadFailureKind.runtimeMissing => Problem('Virtual needs the Microsoft C++ runtime', f.message, const [Fix.getRuntime, Fix.pickBuild]),
          LoadFailureKind.quarantined => Problem(
            'macOS keeps $title in quarantine',
            'Downloaded files are quarantined and refused. Striso Live can clear it.',
            const [Fix.clearQuarantine, Fix.pickBuild],
          ),
          LoadFailureKind.notFound => Problem('$title is gone', 'Its library is no longer at ${f.path}.', const [Fix.pickBuild, Fix.openFolder]),
          LoadFailureKind.other => Problem('Virtual did not start', f.message, const [Fix.playVirtual, Fix.pickBuild]),
        };
      case FailKind.other:
        if (s.mode == Mode.virtual) return Problem('Virtual did not start', s.message, const [Fix.playVirtual, Fix.pickBuild]);
        return Problem('Could not connect', s.message, const [Fix.connectStriso, Fix.playVirtual]);
    }
  }

  /// A fix the controller can do itself (the UI does the ones that need a dialog or a menu).
  Future<void> fix(Fix f) async {
    switch (f) {
      case Fix.connectStriso || Fix.connectNow:
        await userConnect();
      case Fix.playVirtual:
        await playVirtual();
      case Fix.clearQuarantine:
        final p = virtual.libPath;
        if (p == null) return;
        if (!await clearQuarantine(File(p).parent.path)) {
          toast('xattr could not clear the quarantine', 'warn');
          return;
        }
        await useBuild(p);
      case Fix.pickBuild || Fix.installBuild || Fix.openFolder || Fix.copyVersion || Fix.getRuntime:
        break; // the UI's
    }
  }

  // connect, stop, switch --------------------------------------------------------------------------

  /// The Striso, now (the header's Striso segment, Connect Striso, Connect now).
  Future<void> userConnect() async {
    if (saving) return;
    _trace('click', start: true);
    await session.connect(Mode.striso);
  }

  /// Disconnect: everything ends; the Striso stays away until it is connected by hand (also
  /// Cancel while a connect waits).
  Future<void> userDisconnect() => session.disconnect();

  /// Stop (Virtual): everything ends; nothing plays. The Striso's standing is untouched: one
  /// plugged in from now on connects by itself.
  Future<void> userStop() => session.disconnect(why: IdleWhy.stopped);

  /// Virtual on the build chosen (a Striso session ends first).
  Future<bool> playVirtual() async {
    if (saving) return false;
    return session.connect(Mode.virtual);
  }

  /// The header's instrument control.
  Future<void> setMode(Mode m) => m == Mode.virtual ? playVirtual() : userConnect();

  /// The header's trailing button: what [connectLabel] says.
  Future<void> connectButton() async {
    final s = state;
    if (s is Waiting) return userDisconnect();
    if (s is Live || s is Connecting) return s.mode == Mode.virtual ? userStop() : userDisconnect();
  }

  /// The trailing button's label: Cancel (a connect waits), Disconnect (the Striso), Stop
  /// (Virtual); empty when there is nothing to end (the segments are the actions then).
  String get connectLabel {
    final s = state;
    if (s is Waiting) return 'Cancel';
    if (s is Live || s is Connecting) return s.mode == Mode.virtual ? 'Stop' : 'Disconnect';
    return '';
  }

  /// Ends the session (tests, the window closing).
  Future<void> endSession() => session.disconnect();

  /// The Dart mock behind Virtual (widget tests).
  MockBoard? get demoBoard => virtual.mock;

  /// The board the board view plays by hand (Virtual).
  PlayableBoard? get playBoard => isVirtual && connected ? session.board?.hand : null;

  void _route() {
    if (_disposed) return;
    routing.apply(state, virtual.sound);
  }

  // the firmware builds Virtual can run (docs/flows.md 5) --------------------------------------------

  /// The firmware folder in the app data: a folder per build (null in tests with a memory store).
  late final String? firmwareDir;

  /// The build played before the current one, for the ⇄ swap (this run only), and the one that
  /// plays (or played last): a build that did not load counts for neither.
  String? previousBuild, _playedBuild;

  final _probes = <String, BuildProbe>{};

  /// The builds in the firmware folder (and the one in use when it is elsewhere), as the menu
  /// shows them: title, the commit it reports, whether it can load and why not. Each library is
  /// probed once (its C API and firmware version) and not kept loaded.
  List<BuildInfo> buildList() {
    final builds = [...findFirmwareBuilds(firmwareDir)];
    final cur = virtual.libPath;
    if (cur != null && !builds.any((b) => b.path == File(cur).absolute.path)) builds.add(buildOf(cur));
    final board = commitOf(strisoVersion?.fw);
    final out = <BuildInfo>[];
    for (final b in builds) {
      final current = b.path == cur;
      final BuildProbe probe;
      if (current && virtual.lib != null) {
        probe = BuildProbe(0, api: svApiVersion, firmwareVersion: virtual.version);
      } else if (current && virtual.failure != null) {
        probe = BuildProbe(0, api: virtual.failure!.api, failure: virtual.failure);
      } else {
        probe = _probe(b.path);
      }
      final f = probe.failure;
      final commit = commitOf(probe.firmwareVersion);
      out.add(
        BuildInfo(
          b,
          current: current,
          commit: commit,
          onStriso: commit != null && commit == board,
          reason: f == null
              ? null
              : switch (f.kind) {
                  LoadFailureKind.apiMismatch => 'built for another Striso Live (API ${f.api})',
                  LoadFailureKind.notLibrary => 'not a striso_virtual library',
                  LoadFailureKind.runtimeMissing => 'needs the Microsoft C++ runtime',
                  LoadFailureKind.quarantined => 'kept in quarantine by macOS',
                  LoadFailureKind.notFound => 'its library is gone',
                  LoadFailureKind.other => 'does not load',
                },
        ),
      );
    }
    return out;
  }

  BuildProbe _probe(String path) {
    int stamp;
    try {
      final st = File(path).statSync();
      stamp = st.modified.millisecondsSinceEpoch ^ st.size;
    } catch (_) {
      stamp = -1;
    }
    final have = _probes[path];
    if (have != null && have.stamp == stamp) return have;
    BuildProbe r;
    try {
      final p = StrisoVirtualLib.probe(path);
      r = BuildProbe(
        stamp,
        api: p.api,
        firmwareVersion: p.firmwareVersion,
        failure: p.api == svApiVersion ? null : LoadFailure(LoadFailureKind.apiMismatch, path, '', api: p.api),
      );
    } on LoadFailure catch (e) {
      r = BuildProbe(stamp, api: e.api, failure: e);
    } catch (e) {
      r = BuildProbe(stamp, failure: LoadFailure(LoadFailureKind.other, path, '$e'));
    }
    return _probes[path] = r;
  }

  /// The build in use (its library's path), if one is loaded.
  String? get firmwarePath => virtual.lib?.path;

  /// Plays a build: whatever plays ends, the old library is let go of, this one is loaded and
  /// Virtual starts on it; then the voice key you were on is pressed, so the same key plays the
  /// new build's sound (its firmware picks the preset it remembers for the key). Remembered for
  /// the next start when it plays.
  Future<bool> useBuild(String path) async {
    if (saving) return false;
    final b = buildOf(path);
    final key = isVirtual && canSend ? settingsLayout.voiceKeyOf(currentEngine) : null;
    final prev = _playedBuild ?? (virtual.lib != null ? virtual.libPath : null);
    if (state.mode != null) await session.disconnect(why: IdleWhy.modeSwitch);
    final f = virtual.selectLibrary(b.path, title: b.title);
    if (f != null) log('virtual firmware: ${b.title} refused: ${f.message}', LogKind.err);
    notifyListeners();
    final ok = await session.connect(Mode.virtual);
    if (!ok) return false;
    store.set('virtualLib', b.path);
    _playedBuild = b.path;
    if (prev != null && prev != b.path) previousBuild = prev;
    log('virtual firmware: ${b.title} (${virtual.version})');
    if (key != null && settingsLayout[key]?.switchable == true) unawaited(pressSettingsKey(key));
    notifyListeners();
    return true;
  }

  /// ⇄: the build played before this one, on the same key.
  Future<bool> swapBuild() async {
    final p = previousBuild;
    if (p == null) return false;
    return useBuild(p);
  }

  /// Installs a build (a release zip, or a library) into the firmware folder, then plays it.
  /// macOS: its quarantine cleared. False with a toast when it cannot be.
  Future<bool> installAndUseFirmware(String source) async {
    final dir = firmwareDir;
    if (dir == null) {
      toast('There is no firmware folder in this run', 'warn');
      return false;
    }
    final String lib;
    try {
      lib = await installFirmware(source, dir, apiVersion: svApiVersion);
    } catch (e) {
      toast('Not installed: $e', 'err');
      log('firmware install: $e', LogKind.err);
      return false;
    }
    log('virtual firmware installed: $lib');
    return useBuild(lib);
  }

  // SessionHost -----------------------------------------------------------------------------------

  @override
  void say(String text, {bool info = false}) => showBanner(text, info: info);
  @override
  void clearBanner() => hideBanner();

  @override
  void sessionChanged() {
    if (_disposed) return;
    _route();
    notifyListeners();
    audioState.ping();
  }

  @override
  void resourcesChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  Future<FailEv?> boardUp(Board b, bool Function() current) async {
    final c = b.client;
    final usbBoard = b.mode == Mode.striso;
    if (usbBoard) {
      if (_traceClock == null || _traceClock!.elapsedMilliseconds > 60000) _trace('connect', start: true);
      c.trace = (l) => _trace(l);
    }
    c.onStream = (src, id, v, n) => live.apply(src, id, v, n, clockMs());
    c.qErrors.listen((e) {
      final list = params[e.target]?.params ?? const <Param>[];
      final p = list.where((q) => q.index == e.index).firstOrNull;
      toast('The board refused ${e.target < targetNames.length ? targetNames[e.target] : e.target} parameter ${p?.name ?? e.index}', 'warn');
      log('Q err ${e.target} ${e.index}', LogKind.err);
    });
    c.text.listen((l) => logKind(l, LogKind.out));
    c.restreams.listen((q) => log('no stream messages for ${(q / 1000).toStringAsFixed(1)} s while bytes arrive: sent S again', LogKind.err));
    final v = await c.getVersion();
    if (!current()) return null;
    if (!c.open) return const FailEv(FailKind.other, 'The board went away while connecting.');
    if (v == null) {
      return const FailEv(
        FailKind.needsUpdate,
        'The Striso did not answer the version request. Check that it runs the Striso firmware, then unplug and replug it.',
      );
    }
    version = v;
    if (usbBoard) strisoVersion = v;
    log('connected: ${v.line}');
    if (usbBoard) _trace('version');
    // the app needs the current firmware: it reports its settings layout and its state
    final layout = await c.getSettingsLayout();
    final count = layout == null ? null : await c.getChangeCount();
    final hero = count == null ? null : await c.getHeroes();
    if (!current()) return null;
    if (layout == null || count == null || hero == null) {
      return FailEv(FailKind.needsUpdate, b.mode == Mode.virtual ? 'This build is too old for Striso Live (found ${v.fw}).' : 'This Striso needs a firmware update to work with Striso Live (found ${v.fw}).');
    }
    settingsLayout = layout;
    heroes = hero;
    _stateCount = count;
    _applyState(await c.getState());
    await refreshVoices();
    if (!current()) return null;
    if (usbBoard) _trace('voice list (${voices.length})');
    unawaited(c.startStream().catchError((_) {}));
    session.resources.up(Res.stream, 'StcS');
    return null;
  }

  @override
  void boardLive(Board b) {
    final c = b.client;
    if (b.mode == Mode.striso) _trace('live');
    waveT = clockMs();
    // the parameter lists load behind the live view (the pollers wait their turn)
    listsLoading = true;
    notifyListeners();
    bool same() => identical(client, c);
    listsReady = refreshParams(allTargets, voiceChanged: true)
        .then((_) async {
          if (b.mode == Mode.striso && same()) _trace('all lists');
          if (same()) _offerRestore();
          if (same()) await refreshTuning();
        })
        .whenComplete(() {
          if (same()) {
            listsLoading = false;
            notifyListeners();
          }
        });
    session.every(Res.loadPoll, const Duration(seconds: 1), () => _loadOnce(c));
    // the board's change counter: anything that changed on the instrument (Settings + a key, the
    // octave buttons) or anywhere else is read again from the board
    session.every(Res.statePoll, const Duration(milliseconds: 250), () => _pollState(c), what: 'Stcy every 250 ms');
    if (b.mode == Mode.striso) unawaited(_pollUsbAudio(c));
    _scheduleTuningPoll();
    // the first time Virtual plays: every MIDI input there is plays it (the picker changes that)
    final m = midi;
    if (b.mode == Mode.virtual && m != null && store.raw('midi') == null) {
      for (final d in m.devices) {
        if (d.present && !d.isVirtual) m.select(d.id, true);
      }
      store.set('midi', m.toJson());
    }
  }

  @override
  void boardDown() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    listsLoading = false;
    settingsLayout = SettingsLayout.empty;
    heroes = null;
    boardState = null;
    _stateCount = null;
    _resetUi();
  }

  void _applyState(BoardState? st) {
    if (st == null) return;
    boardState = st;
    final t = st.transpose;
    if (t != null) live.setTranspose(t.round());
  }

  /// One round of the state poll: the counter moved, so the state, the voice and the values are
  /// read again (the app shows what the board says, never what it guessed).
  Future<void> _pollState(StrisoClient c) async {
    if (_stateBusy || !identical(client, c) || state is! Live || saving) return;
    _stateBusy = true;
    try {
      final n = await c.getChangeCount();
      if (n == null || !identical(client, c) || n == _stateCount) return;
      // an edit in progress: its own read-back comes after the gesture
      if (clockMs() - sound.editT < 400) return;
      _stateCount = n;
      await _readBoard(c);
    } finally {
      _stateBusy = false;
    }
  }

  /// The state, the voice list and every parameter value, as the board has them now.
  Future<void> _readBoard(StrisoClient c) async {
    _applyState(await c.getState());
    if (!identical(client, c)) return;
    await _voiceBusy;
    final before = current;
    await refreshVoices();
    if (!identical(client, c)) return;
    if (current != before) {
      lastSound = null;
      await refreshParams([0, 1], voiceChanged: true);
      await readBack([2, 3]);
    } else {
      await readBack(allTargets);
    }
    await _readHeroes(c);
    await refreshTuning();
    notifyListeners();
  }

  void _resetUi() {
    sound.clear();
    live.clear();
    voices = const [];
    current = -1;
    voiceName = '';
    morph.load(null);
    version = null;
    load = null;
    loadNa = false;
    loadHist.clear();
    tuning = null;
    tuningSupported = null;
    _tuningSuggested = false;
    harmony.reset();
    if (_disposed) return;
    notifyListeners();
    values.ping();
  }

  // ---------------------------------------------------------------------------------------------
  // voices

  Future<void> refreshVoices() async {
    final c = client;
    if (c == null) return;
    final v = await c.listVoices();
    if (!identical(c, client)) return;
    voices = v;
    final cur = v.where((x) => x.current).firstOrNull;
    current = cur?.index ?? -1;
    notifyListeners();
  }

  Future<void> selectVoice(int n) {
    _voiceBusy = _voiceBusy.then((_) => _doSelectVoice(n)).catchError((Object e) => showBanner('$e'));
    return _voiceBusy;
  }

  int pendingVoice = -1;

  Future<void> _doSelectVoice(int n) async {
    final c = client;
    if (c == null || !canSend || n == current) return;
    pendingVoice = n;
    notifyListeners();
    final r = await c.selectVoice(n);
    pendingVoice = -1;
    if (!identical(c, client)) return;
    if (r == null || !r.ok) {
      toast(r != null ? 'The board has no voice $n' : 'The board did not confirm the voice change', 'error');
      notifyListeners();
      return;
    }
    current = r.index;
    lastSound = null;
    notifyListeners();
    // the synth thread switches at the next audio block and loads the preset's values
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await refreshParams([0, 1], voiceChanged: true);
    if (identical(c, client)) await _readHeroes(c);
  }

  /// The voice as the board reports it (it can change on the instrument: Settings + a voice key).
  Future<void> syncVoice() async {
    final c = client;
    if (c == null || connecting) return;
    await _readBoard(c);
  }

  void stepVoice(int dir) {
    if (voices.isEmpty) return;
    final k = voices.indexWhere((v) => v.index == current);
    final next = voices[(k + dir + voices.length) % voices.length];
    selectVoice(next.index);
  }

  String get nowEngine {
    if (voiceName.isEmpty) return '';
    return engineInfo(voiceName.split(':').first).label;
  }

  String get nowPreset {
    if (voiceName.isEmpty) return 'No voice';
    final i = voiceName.indexOf(':');
    return i >= 0 ? voiceName.substring(i + 1) : engineInfo(voiceName).label;
  }

  // ---------------------------------------------------------------------------------------------
  // parameters

  Future<void> refreshParams(List<int> targets, {bool voiceChanged = false}) async {
    final c = client;
    if (c == null) return;
    for (final t in targets) {
      var r = await c.getParams(t);
      // a text line can be lost if the board drops part of a stream message: read once more
      if (r != null && !r.complete && identical(c, client)) r = (await c.getParams(t)) ?? r;
      if (!identical(c, client)) return;
      if (r == null) {
        sound.load(t, const ParamSet('', [], missing: true));
      } else {
        sound.load(t, ParamSet(r.name, [for (final p in r.params) p..loadValue = p.value], complete: r.complete));
        if (!r.complete) toast('Only ${r.params.length} of ${r.count} ${targetNames[t]} parameters arrived', 'warn');
      }
    }
    if (targets.contains(0)) {
      voiceName = params[0]!.name.isNotEmpty ? params[0]!.name : (voices.where((v) => v.index == current).firstOrNull?.name ?? '');
      if (voiceChanged) {
        history.clear();
        final stored = _morphStore[voiceName];
        if (stored is Map) {
          final cs = stored['corners'];
          final pos = stored['pos'];
          morph.load(
            cs is List ? [for (var i = 0; i < 4; i++) i < cs.length ? Corner.fromJson(cs[i]) : null] : null,
            pos is List && pos.length == 2 ? [(pos[0] as num).toDouble(), (pos[1] as num).toDouble()] : null,
          );
        } else {
          morph.load(null);
        }
      }
    }
    notifyListeners();
    values.ping();
  }

  // morph host ----------------------------------------------------------------------------------

  @override
  Snapshot? morphCapture() {
    if (client == null || voiceName.isEmpty) {
      toast('Connect first, then capture the sound you hear.', 'warn');
      return null;
    }
    final snap = snapshot({0: params[0]!.params, 1: params[1]!.params}, voiceName);
    final edited = [...params[0]!.params, ...params[1]!.params].any((p) => p.value != p.loadValue);
    final base = lastSound ?? voiceName.split(':').last;
    snap.label = edited && lastSound == null ? '$base, edited' : base;
    notifyListeners();
    return snap;
  }

  @override
  void morphApply(List<double>? weights, List<Snapshot?>? corners, String phase, [String? key]) {
    if (phase == 'begin') {
      history.begin('Morph', key ?? 'morph');
      return;
    }
    if (phase == 'end') {
      history.commit();
      notifyListeners();
      return;
    }
    final targets = morph.includeFx ? [0, 1] : [0];
    final record = phase == 'change';
    for (final t in targets) {
      for (final (p, v) in morphValues(params[t]!.params, corners!, weights!, t)) {
        setValue(t, p, v, record: record);
      }
    }
  }

  @override
  String get morphVoice => voiceName;

  @override
  ({double ax, double ay, double abs, bool fresh}) get morphMotion {
    final m = live.motion;
    return (ax: m.ax, ay: m.ay, abs: m.abs, fresh: clockMs() - m.t < 1500);
  }

  @override
  void morphSave(String voice, Map<String, Object?> state) {
    if (voice.isEmpty) return;
    _morphStore[voice] = state;
    store.set('morph', _morphStore);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------
  // user presets

  void _savePresets() {
    if (!store.set('presets', [for (final p in presets) p.toJson()])) toast('Could not save the sounds to disk', 'error');
    notifyListeners();
  }

  void saveCurrent(String name) {
    if (client == null || voiceName.isEmpty) {
      toast('Connect first: a sound is saved from the board', 'warn');
      return;
    }
    final t = DateTime.now();
    name = name.trim();
    if (name.isEmpty) name = '${voiceName.split(':').last} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final p = makePreset(name, voiceName, {0: params[0]!.params, 1: params[1]!.params});
    final k = presets.indexWhere((q) => q.name == name);
    if (k >= 0) {
      presets[k] = p;
    } else {
      presets.insert(0, p);
    }
    _savePresets();
    lastSound = name;
    toast(k >= 0 ? 'Replaced "$name"' : 'Saved "$name"');
  }

  Future<void> recallPreset(Preset pr) async {
    if (client == null) {
      toast('Connect first to recall a sound', 'warn');
      return;
    }
    final v = voices.where((x) => x.name == pr.voice).firstOrNull ?? voices.where((x) => x.engine == pr.engine).firstOrNull;
    if (v == null && voices.isNotEmpty) {
      toast('This firmware has no ${pr.engine} voice', 'error');
      return;
    }
    if (v != null && v.index != current) await selectVoice(v.index);
    if (voiceName.isNotEmpty && voiceName.split(':').first != pr.engine) {
      toast('"${pr.name}" is for ${pr.engine}, the board plays $voiceName', 'error');
      return;
    }
    history.begin('Recall ${pr.name}');
    final missing = <String>[];
    for (final t in soundTargets) {
      for (final q in t == 1 ? pr.fx : pr.params) {
        final p = findParam(t, q.name);
        if (p != null) {
          setValue(t, p, q.value);
        } else {
          missing.add(q.name);
        }
      }
    }
    history.commit();
    _flushValues();
    lastSound = pr.name;
    notifyListeners();
    toast(
      missing.isNotEmpty
          ? 'Recalled "${pr.name}"; this firmware lacks ${missing.take(3).join(', ')}${missing.length > 3 ? '…' : ''}'
          : 'Recalled "${pr.name}"',
      missing.isNotEmpty ? 'warn' : '',
    );
  }

  void renamePreset(Preset p, String name) {
    name = name.trim();
    if (name.isEmpty || name == p.name) return;
    final k = presets.indexOf(p);
    if (k < 0) return;
    presets.removeWhere((q) => q.name == name && !identical(q, p));
    presets[presets.indexOf(p)] = Preset(name: name, voice: p.voice, engine: p.engine, created: p.created, params: p.params, fx: p.fx);
    if (lastSound == p.name) lastSound = name;
    _savePresets();
    toast('Renamed to "$name"');
  }

  String exportPreset(Preset p) => collectionJson([p]);

  void deletePreset(Preset p) {
    presets.remove(p);
    _savePresets();
    toast('Deleted "${p.name}"');
  }

  String exportPresets() => collectionJson(presets);

  void importPresets(String text) {
    final r = parsePresetFile(text);
    for (final p in r.presets) {
      final k = presets.indexWhere((q) => q.name == p.name);
      if (k >= 0) {
        presets[k] = p;
      } else {
        presets.add(p);
      }
    }
    _savePresets();
    if (r.errors.isNotEmpty) {
      toast('Imported ${r.presets.length}, skipped ${r.errors.length}: ${r.errors.first}', 'warn');
    } else {
      toast('Imported ${r.presets.length} sound${r.presets.length == 1 ? '' : 's'}');
    }
  }

  Preset currentAsPreset() => makePreset(lastSound ?? voiceName.split(':').last, voiceName, {0: params[0]!.params, 1: params[1]!.params});

  // ---------------------------------------------------------------------------------------------
  // synth load

  /// While Through PC plays: the board's own USB audio counters every 2 s (StcU; they reset on
  /// every call), so a dropout can be told apart: on the board, in the computer's input, in its
  /// output. The first reply after starting only sets the baseline (it counts since whenever U
  /// was last asked). Firmware that does not answer is not asked again in this session.
  Future<void> _pollUsbAudio(StrisoClient c) => BoardAudioLink(
    audio: audio,
    getStats: c.getUsbAudioStats,
    setTarget: c.setUsbAudioTarget,
    alive: () => identical(client, c) && !_disposed && state is Live,
    paused: () => connecting || saving,
    log: (s) => log(s),
    onTarget: audioState.ping,
  ).run();

  bool _loadBusy = false;

  /// One load reading (the session's load poller, every second).
  Future<void> _loadOnce(StrisoClient c) async {
    if (_loadBusy || !identical(client, c) || state is! Live) return;
    _loadBusy = true;
    try {
      final l = await c.getLoad();
      if (!identical(client, c)) return;
      if (l != null) {
        _loadMisses = 0;
        loadNa = false;
        load = l;
        if (l.blocks > 0) {
          loadHist.add(l);
          if (loadHist.length > 90) loadHist.removeAt(0);
        }
        notifyListeners();
      } else if (++_loadMisses == 3) {
        loadNa = true;
        notifyListeners();
      }
    } finally {
      _loadBusy = false;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // key, scale highlighting and harmony

  void setNames(Names n) {
    names = n;
    store.set('names', n.name);
    notifyListeners();
    _scheduleTuningPoll();
  }

  void setColour(KeyColour c) {
    colour = c;
    store.set('colour', c.name);
    notifyListeners();
  }

  void setPitchRef(PitchRef r) {
    pitchRef = r;
    store.set('pitchRef', r.name);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------
  // the board's tuning (StcN): what every key plays

  /// The tuning as the board last reported it; null before the first reply or without support.
  TuningInfo? tuning;

  /// null: not asked yet; false: the firmware gave no reply (no N command); true: it answers.
  bool? tuningSupported;
  bool _tuningSuggested = false, _tuningBusy = false;

  /// Pitch labels want the tuning: N is asked for on connect, after the Settings button is
  /// released, and every 2 s while pitch or cents labels show (a cheap one-line poll).
  bool get _wantsTuningPoll => client != null && (names == Names.pitch || names == Names.cents) && tuningSupported != false;

  void _scheduleTuningPoll() {
    if (!_wantsTuningPoll || state is! Live) {
      session.stopEvery(Res.tuningPoll);
      return;
    }
    if (session.runs(Res.tuningPoll)) return;
    session.every(Res.tuningPoll, const Duration(seconds: 2), () {
      if (!_wantsTuningPoll) {
        session.stopEvery(Res.tuningPoll);
        return;
      }
      if (canSend && !saving) refreshTuning();
    });
  }

  /// Ask the board for its tuning. Old firmware answers with nothing: that is remembered for the
  /// session and the labels fall back to 12-TET from the layout.
  Future<void> refreshTuning() async {
    final c = client;
    if (c == null || _tuningBusy) return;
    _tuningBusy = true;
    try {
      final t = await c.getTuning();
      if (!identical(c, client)) return;
      if (t == null) {
        if (tuningSupported == null) log('no tuning reply (StcN): labels assume 12-TET from the layout');
        tuningSupported = false;
        tuning = null;
      } else {
        if (tuningSupported != true) log('tuning: ${t.nameIn(settingsLayout).name}${t.referenceText != null ? ', ${t.referenceText}' : ''}');
        tuningSupported = true;
        final was = tuning?.nameIn(settingsLayout).name;
        tuning = t;
        if (!t.isPlain12 && !_tuningSuggested && names != Names.pitch && names != Names.cents) {
          _tuningSuggested = true;
          toastAction(
            'The Striso plays ${t.nameIn(settingsLayout).name}${t.referenceText != null ? ' at ${t.referenceText}' : ''}',
            'Pitch labels',
            () => setNames(Names.pitch),
          );
        } else if (was != null && was != t.nameIn(settingsLayout).name) {
          toast('Tuning: ${t.nameIn(settingsLayout).name}');
        }
      }
      notifyListeners();
    } finally {
      _tuningBusy = false;
      _scheduleTuningPoll();
    }
  }

  /// The tuning's names: from the N reply, else 12-TET (the layout's assumption).
  String get tuningName => tuning?.nameIn(settingsLayout).name ?? '12-TET';
  String get tuningShort => tuning?.nameIn(settingsLayout).short ?? '12TET';

  /// The board plays something other than 12-TET (chord names stay spelled, 12-TET by letter).
  bool get nonTwelve {
    final t = tuning;
    return t != null && (t.hasKeyOffsets || (t.fifthCents - 700).abs() >= 0.02 || (t.octaveCents - 1200).abs() >= 0.05);
  }

  /// What a key plays, MIDI-like semitones: the board's word, else 12-TET from the layout.
  double keyPitch(int id) => tuning?.pitchOfButton(id) ?? (startNote + pitchOf(id) + live.transpose).toDouble();

  /// The pitch a label is drawn from: the fine tune is taken out (the chip shows it), and with the
  /// root reference the key's root is made exact.
  double labelPitch(int id) {
    var p = keyPitch(id) - (tuning?.offset ?? 0);
    if (pitchRef == PitchRef.root) p -= rootShift;
    return p;
  }

  /// How far the key root's key is from 12-TET (semitones), the shift the root reference removes.
  double get rootShift {
    final t = tuning;
    if (t == null) return 0;
    final tonic = currentKey?.tonic ?? 0; // C when there is no key
    // the key with this spelling nearest the middle of the board
    int? best;
    for (final id in keyIds) {
      if (keyTpc(id, live.transposeFifths) != tonic) continue;
      if (best == null || pitchOf(id).abs() < pitchOf(best).abs()) best = id;
    }
    if (best == null) return 0;
    final p = t.pitchOfButton(best);
    if (p == null) return 0;
    final nominal = startNote + pitchOf(best) + live.transpose;
    return p - t.offset - nominal;
  }

  /// The quarter-tone label of a key on its spelled letter.
  QtLabel qtLabel(int id) {
    final n = noteName(id, live.transpose, live.transposeFifths);
    return quarterToneLabel(labelPitch(id), n.letter, nominalMidi: n.midi);
  }

  /// Demo: load one of the settings card's tunings on the simulated board, and the fine tune.
  void demoTuning(int n, {double? fineCents}) {
    final b = playBoard;
    if (b is! MockBoard) {
      // the virtual board: the settings card's tuning keys (12-TET, tunings 1..8)
      final key = settingsLayout.keys.entries.where((e) => e.value.tuningIndex == n).firstOrNull?.key;
      if (b != null && key != null) unawaited(pressSettingsKey(key));
      return;
    }
    b.loadTuning(n);
    if (fineCents != null) b.fineTune(fineCents);
    refreshTuning();
  }

  void setKey({int? root, String? scale}) {
    if (root != null) keyRoot = root;
    if (scale != null) keyScale = scale;
    currentKey = makeKey(keyRoot, keyScale);
    store.set('key', {'root': keyRoot, 'scale': keyScale});
    harmony.setKey(currentKey);
    notifyListeners();
  }

  /// The roots in the picker, around the circle of fifths, spelled for the scale.
  List<(int, String)> get rootChoices {
    final spellAs = keyScale == 'off' ? 'major' : keyScale;
    return [for (var k = 0; k < 12; k++) ((k * 7) % 12, tpcName(spellTonic((k * 7) % 12, spellAs)))];
  }

  void useSuggestedKey() {
    final est = harmony.suggestion;
    if (est == null) return;
    setKey(root: est.pc, scale: est.mode == 'major' ? 'major' : 'minor');
    toast('Key set to ${est.name}');
  }

  // ---------------------------------------------------------------------------------------------
  // key equalizer

  Param? keyParam(int buttonId) {
    final n = keyNumberOf[buttonId];
    if (n == null) return null;
    final list = params[3]!.params;
    if (n < list.length && list[n].index == n) return list[n];
    return list.where((p) => p.index == n).firstOrNull;
  }

  double lastPeakOf(int id) => live.lastPeakT[id] > eqSinceT ? live.lastPeak[id] : 0;

  List<Measured> measuredKeys() {
    final out = <Measured>[];
    for (final MapEntry(key: id, value: n) in keyNumberOf.entries) {
      final peak = lastPeakOf(id);
      final p = peak > 0 ? keyParam(id) : null;
      if (p != null) out.add(Measured(n: n, id: id, peak: peak, factor: p.value, name: noteName(id, live.transpose, live.transposeFifths).full));
    }
    return out;
  }

  double? computeEqMedian(List<Measured> ms) {
    final ok = [
      for (final m in ms)
        if (m.peak >= 0.03 && m.peak <= 1.7) m.peak,
    ];
    return ok.length >= 2 ? median(ok) : null;
  }

  void setEqOn(bool on) {
    eqOn = on;
    store.set('eq', {'on': eqOn, 'follow': eqFollow});
    notifyListeners();
    values.ping();
  }

  void setEqFollow(bool on) {
    eqFollow = on;
    store.set('eq', {'on': eqOn, 'follow': eqFollow});
    notifyListeners();
  }

  void eqSelect(int id) {
    if (!keyNumberOf.containsKey(id) || eqSelected == id) return;
    eqSelected = id;
    values.ping();
  }

  String eqLabel(int id) => 'Key ${noteName(id, live.transpose, live.transposeFifths).full} sensitivity';

  void eqSetFactor(double v, String phase) {
    final p = keyParam(eqSelected);
    if (p == null) return;
    onEdit(3, p, (v * 1000).round() / 1000, phase, eqLabel(eqSelected), 'eq:${p.index}');
  }

  void eqStep(double f) {
    final p = keyParam(eqSelected);
    if (p == null) return;
    final v = (p.value * f * 1000).round() / 1000;
    onEdit(3, p, v, 'begin', eqLabel(eqSelected));
    onEdit(3, p, v, 'end');
  }

  void eqResetKey() {
    final p = keyParam(eqSelected);
    if (p == null) return;
    final l = 'Reset ${eqLabel(eqSelected).toLowerCase()}';
    onEdit(3, p, 1, 'begin', l);
    onEdit(3, p, 1, 'end');
  }

  void eqResetAll() {
    history.begin('Reset all key factors');
    for (final p in params[3]!.params) {
      setValue(3, p, 1);
    }
    history.commit();
    _flushValues();
  }

  void eqClear() {
    eqSinceT = clockMs();
    eqMeterReset++;
    values.ping();
  }

  int eqMeterReset = 0;

  /// null and a toast when there is nothing to suggest.
  Suggestion? eqSuggest() {
    final r = suggestFactors(measuredKeys());
    if (r.median == null) {
      toast('Press at least 3 keys with the same feel first (${r.used} usable so far)', 'warn');
      return null;
    }
    if (r.changes.isEmpty) {
      toast('The measured keys are already even');
      return null;
    }
    return r;
  }

  void eqApply(Suggestion r) {
    history.begin('Suggest key factors');
    var n = 0;
    for (final c in r.changes) {
      final p = keyParam(c.key.id);
      if (p != null && setValue(3, p, c.to)) n++;
    }
    history.commit();
    _flushValues();
    eqSinceT = clockMs(); // a fresh round: press the keys again to check
    toast('Changed $n key factor${n == 1 ? '' : 's'}. Press the keys again to check; Undo brings them back.');
  }

  // touch panel ---------------------------------------------------------------------------------

  static const touchDefaults = {'pressure': 1.0, 'velocity': 1.0, 'tilt': 1.0, 'bend': 0.5, 'threshold': 0.0};

  // ---------------------------------------------------------------------------------------------
  // saving touch settings and key factors to the board

  void _setSaveStatus(String text, [String cls = '']) {
    saveStatus = SaveStatus(text, cls);
    notifyListeners();
  }

  /// null when a save may start (the UI then asks for confirmation), else why not.
  String? canSave() {
    final mockOnly = isVirtual && virtual.isMock;
    if (!canSend || (mockOnly && options.fakeSave == null)) {
      toast(mockOnly ? 'The demo keeps its settings until you restart it' : 'Connect the Striso first', 'warn');
      return 'not connected';
    }
    if (params[2]!.params.isEmpty && params[3]!.params.isEmpty) {
      toast('This firmware has no touch settings to save', 'warn');
      return 'no settings';
    }
    return null;
  }

  /// Save to Striso: the touch settings and key factors into the board's settings (preset 1),
  /// through its bootloader's drive (the Striso's, or the virtual Striso's own), then the restart
  /// and the read-back.
  Future<void> doSave() async {
    final c = client, b = session.board;
    if (c == null || b == null || state is! Live) return;
    saving = true;
    notifyListeners();
    final virtualSave = b.mode == Mode.virtual && !virtual.isMock;
    // the values as the board lists them right now
    await refreshParams([2, 3]);
    final values = TouchValues([for (final p in params[2]!.params) (p.name, p.value)], [for (final p in params[3]!.params) (p.name, p.value)]);
    final expect = {2: values.touch, 3: values.keys};
    _setSaveStatus('Putting the Striso into update mode…');
    log('saving touch settings${options.fakeSave != null ? ' (fake save: ${options.fakeSave})' : ''}');
    // the board reboots into its bootloader: the write may fail as it goes
    if (options.fakeSave == null) {
      try {
        if (c.open) await c.send(Cmd.bootloader()).timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    await session.beginReboot('save');
    final res = await saveTouch(
      values,
      backupDir: backupDir,
      progress: (t) => _setSaveStatus(t),
      fake: options.fakeSave,
      roots: virtualSave ? () => b.saveRoots ?? const [] : null,
    );
    saving = false;
    log('save: ${res.ok ? 'ok' : 'failed'}: ${res.message}', res.ok ? LogKind.info : LogKind.err);
    _setSaveStatus(res.ok ? 'Saved. Reconnecting…' : 'Saving failed. Reconnecting…', res.ok ? '' : 'err');
    final back = await session.comeBack();
    if (virtualSave && back) virtual.keepFlash(); // its settings, kept on this computer
    if (!res.ok) {
      final msg = 'Saving failed: ${res.message}${res.backupPath != null ? '. The previous settings are backed up in ${res.backupPath}.' : ''}';
      _setSaveStatus(msg, 'err');
      showBanner(msg);
      return;
    }
    if (!back) {
      _setSaveStatus('Saved, but the app could not reconnect: click Connect.', 'err');
      return;
    }
    await listsReady;
    final diff = <String>[];
    for (final t in [2, 3]) {
      for (final (name, v) in expect[t]!) {
        final p = findParam(t, name);
        if (p == null || (p.value - v).abs() > 2e-3 * math.max(1, v.abs())) diff.add(name);
      }
    }
    if (diff.isNotEmpty) {
      _setSaveStatus('Saved, but ${diff.length} value${diff.length == 1 ? '' : 's'} read back differently: ${diff.take(5).join(', ')}.', 'err');
    } else {
      final t = DateTime.now();
      String p(int n) => n.toString().padLeft(2, '0');
      _setSaveStatus(
        'Saved and read back at ${p(t.hour)}:${p(t.minute)}:${p(t.second)}${res.backupPath != null ? '; the previous settings are in ${res.backupPath}' : ''}.',
        'ok',
      );
      toast('Touch settings saved to the Striso');
    }
  }

  // ---------------------------------------------------------------------------------------------
  // settings overlay

  void toggleSettings([bool? on]) {
    settingsOn = on ?? !settingsOn;
    store.set('settingsOverlay', settingsOn);
    notifyListeners();
  }

  Map<String, SettingsVoice> settingsVoices() {
    final out = <String, SettingsVoice>{};
    for (final f in settingsLayout.keys.values) {
      final e = f.engine;
      if (e == null) continue;
      final list = voices.where((v) => v.engine == e).toList();
      final at = list.indexWhere((v) => v.index == current);
      out[e] = SettingsVoice(list.length, at >= 0, at >= 0 ? (list[at].preset ?? '') : '', list);
    }
    return out;
  }

  /// A click on a key while the overlay shows: select it; a voice key picks the voice like the
  /// Striso does. Returns true when the click was taken.
  bool settingsClick(int id) {
    if (!settingsOn) return false;
    final f = settingsLayout[id];
    // without a board there is no layout (the board lists it): nothing to select, no pulse
    if (!canSend) return true;
    settingsSelected = id;
    // a switch key (voice keys too) is pressed on the board: the firmware does what it does
    if (f != null && f.switchable) unawaited(pressSettingsKey(id));
    notifyListeners();
    return true;
  }

  /// A switch key of the settings overlay, pressed over USB (StcK): the led pulses, the board
  /// answers, and what it changed is read again (the tuning; the touch settings and voice for a
  /// settings preset). Firmware without K gets a one-time hint.
  Future<bool> pressSettingsKey(int id) async {
    final c = client;
    final f = settingsLayout[id];
    if (c == null || !canSend || f == null || !f.switchable) return false;
    ledPulseT = clockMs();
    notifyListeners();
    final r = await c.pressSettingsKey(id);
    if (!identical(c, client)) return false;
    if (r == null || !r.ok) {
      toast('The board refused: ${f.title}', 'warn');
      log('K ${r == null ? 'no reply' : 'err'} $id', LogKind.err);
      return false;
    }
    log('K ok $id: ${f.title}');
    // what it changed, as the board reports it
    final n = await c.getChangeCount();
    if (!identical(c, client)) return false;
    _stateCount = n ?? _stateCount;
    await _readBoard(c);
    if (f.group == SettingsGroup.preset) toast('Loaded ${f.title.replaceFirst('Load ', '')}');
    if (f.group == SettingsGroup.midi) toast(f.title);
    if (id == 63) toast('All notes off');
    notifyListeners();
    return true;
  }

  /// When the indicator led was last made to pulse by an app action (ms, app clock).
  double ledPulseT = -1e9;

  /// Mono legato as the board reports it (StcY `legato=0|1`); null when this firmware has none.
  bool? get legato => switch (boardState?.fields['legato']) {
    '1' => true,
    '0' => false,
    _ => null,
  };

  /// The legato settings key (StcX row 9): the board switches it and the state is read back.
  static const legatoKey = 9;
  bool get legatoSwitchable => canSend && settingsLayout[legatoKey]?.switchable == true;
  Future<bool> toggleLegato() => pressSettingsKey(legatoKey);

  /// A click on a key on the board (not in demo play).
  bool boardSelect(int id, {bool overlays = true}) {
    if (overlays && settingsClick(id)) return true;
    eqSelect(id);
    return false;
  }

  // ---------------------------------------------------------------------------------------------
  // tabs, engines and the main knobs of the Play tab

  AppTab tab = AppTab.play;
  bool morphOpen = false;

  void setTab(AppTab t) {
    if (tab == t) return;
    tab = t;
    hover = -1;
    hoverControl = -1;
    store.set('tab', t.name);
    notifyListeners();
  }

  void setMorphOpen(bool open) {
    morphOpen = open;
    store.set('morphOpen', open);
    notifyListeners();
  }

  /// The engine buttons, as the board lists its voices.
  List<EngineButton> engines() {
    // the engines in the board's voice order (Stcv), each in its voice key's led colour (StcX);
    // an engine without a voice key gets a colour of its own
    final out = <EngineButton>[];
    final seen = <String>{};
    final leds = {for (final (_, engine, led) in settingsLayout.voiceKeys) engine: led};
    var k = 0;
    for (final v in voices) {
      if (!seen.add(v.engine)) continue;
      final led = leds[v.engine];
      final colour = led != null ? ledColor(led) : HSLColorInt.of(engineInfo(v.engine, k++).hue);
      out.add(EngineButton(v.engine, colour, voices.where((x) => x.engine == v.engine).length));
    }
    return out;
  }

  String get currentEngine => voices.where((v) => v.index == current).firstOrNull?.engine ?? (voiceName.isEmpty ? '' : voiceName.split(':').first);

  /// The engine button: the engine's voice key pressed on the board (StcK), so the firmware picks
  /// the preset it remembers; an engine without a voice key: its first preset.
  void selectEngine(String engine) {
    if (!canSend) {
      toast(connecting ? 'Connecting…' : 'Connect to switch voices', 'warn');
      return;
    }
    final key = settingsLayout.voiceKeyOf(engine);
    if (key != null) {
      unawaited(pressSettingsKey(key));
      return;
    }
    final first = voices.where((v) => v.engine == engine).firstOrNull;
    if (first == null) {
      toast('This firmware has no ${engineInfo(engine).label} voice', 'warn');
      return;
    }
    if (first.index != current) selectVoice(first.index);
  }

  /// About eight knobs that matter most for the current voice, then the effect amounts.
  /// The hero knobs, as the board names them for this voice (StcH): its parameters by those names.
  List<Param> mainKnobs() => _heroParams(0, _heroesNow?.params ?? const []);
  List<Param> mainFx() => _heroParams(1, _heroesNow?.fx ?? const []);

  /// The heroes the board gave for the voice it plays now (none while the new voice's are read).
  HeroKnobs? get _heroesNow => heroes != null && heroes!.voice == current ? heroes : null;

  /// Hero names the board gave that its parameter lists do not have: shown as an error, never
  /// replaced by a guess.
  List<String> get heroMissing {
    final h = _heroesNow;
    if (h == null || listsLoading || params[0]!.params.isEmpty) return const [];
    return [
      for (final n in h.params)
        if (findParam(0, n) == null) n,
      for (final n in h.fx)
        if (params[1]!.params.isNotEmpty && findParam(1, n) == null) n,
    ];
  }

  List<Param> _heroParams(int t, List<String> names) => [
    for (final n in names) ?findParam(t, n),
  ];

  Future<void> _readHeroes(StrisoClient c) async {
    final h = await c.getHeroes();
    if (!identical(c, client) || h == null) return;
    heroes = h;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------
  // stage mode, the console drawer, the Setup mode, the shortcut overlay

  bool stage = false, consoleOpen = false, shortcutsOpen = false;

  void setStage(bool on) {
    if (stage == on) return;
    stage = on;
    notifyListeners();
  }

  void setConsole(bool open) {
    consoleOpen = open;
    notifyListeners();
  }

  void setShortcuts(bool open) {
    shortcutsOpen = open;
    notifyListeners();
  }

  SetupMode get setupMode => settingsOn ? SetupMode.settings : (eqOn ? SetupMode.equalizer : SetupMode.sensitivity);

  void setSetupMode(SetupMode m) {
    settingsOn = m == SetupMode.settings;
    eqOn = m == SetupMode.equalizer;
    store.set('settingsOverlay', settingsOn);
    store.set('eq', {'on': eqOn, 'follow': eqFollow});
    notifyListeners();
    values.ping();
  }

  // ---------------------------------------------------------------------------------------------
  // the edited sound per voice, kept on this computer: the board forgets edits on a restart

  Timer? _editsTimer;

  void _rememberEditsSoon() {
    if (abOn || voiceName.isEmpty) return;
    _editsTimer?.cancel();
    final voice = voiceName;
    _editsTimer = Timer(const Duration(milliseconds: 800), () => _rememberEdits(voice));
  }

  void _rememberEdits(String voice) {
    if (_disposed || voice != voiceName || abOn) return;
    final all = (store.raw('edits') as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    final mine = <String, Object?>{
      for (final t in soundTargets)
        '$t': {
          for (final p in params[t]!.params)
            if (p.value != p.loadValue) p.name: p.value,
        },
    };
    if ((mine['0'] as Map).isEmpty && (mine['1'] as Map).isEmpty) {
      all.remove(voice);
    } else {
      all[voice] = mine;
    }
    store.set('edits', all);
  }

  /// After a reconnect: the edits this computer kept for the board's voice, if the board lost them.
  void _offerRestore() {
    final all = store.raw('edits');
    if (all is! Map) return;
    final mine = all[voiceName];
    if (mine is! Map) return;
    final changes = <(int, Param, double)>[];
    for (final t in soundTargets) {
      final m = mine['$t'];
      if (m is! Map) continue;
      for (final e in m.entries) {
        final p = findParam(t, e.key as String);
        final v = (e.value as num?)?.toDouble();
        if (p != null && v != null && conformValue(p, v) != p.value) changes.add((t, p, v));
      }
    }
    if (changes.isEmpty) return;
    final preset = voiceName.split(':').last;
    toastAction('Your edited $preset is back', 'Restore', () {
      history.begin('Restore edited $preset');
      for (final (t, p, v) in changes) {
        setValue(t, p, v);
      }
      history.commit();
      _flushValues();
      notifyListeners();
    });
  }

  // ---------------------------------------------------------------------------------------------
  // animation frame and readouts

  double _lastStats = 0;

  void frame(double now, double dt) {
    harmony.frame(now);
    if (morph.frame(now, dt)) morphPulse.ping();
    _flushValues();
    live.tickRate(now);
    if (now - _lastStats > 120) {
      _lastStats = now;
      eqMedian = computeEqMedian(measuredKeys());
      stats.ping();
    }
  }

  /// The morph pad moved or changed.
  final morphPulse = Pulse();

  /// Tell the widgets that something changed.
  void changed() => notifyListeners();

  int _lastRx = 0;
  double _lastRxT = 0;

  String diagnosticsText() {
    final c = client;
    if (c == null) return 'Not connected.';
    final d = c.diagnostics();
    final now = clockMs();
    final dt = (now - _lastRxT) / 1000;
    final bps = _lastRx > 0 && dt > 0 ? math.max(0, (d.rxBytes - _lastRx) / dt) : 0;
    if (dt >= 0.5) {
      _lastRx = d.rxBytes;
      _lastRxT = now;
    }
    final since = d.sinceMessage == null ? 'never' : '${(d.sinceMessage!.inMilliseconds / 1000).toStringAsFixed(1)} s ago';
    final p = d.parser;
    return 'rx ${(bps / 1000).toStringAsFixed(1)} kB/s (${d.rxBytes} bytes)  |  stream ${d.streaming ? 'on' : 'off'}, last message $since, '
        'restarts ${d.restarts}  |  parser: ${p.messages} messages, ${p.lines} lines, ${p.textBytes} text bytes, ${p.truncated} truncated  |  '
        'live ${live.rate.round()} msg/s  |  commands queued ${d.queued}';
  }

  bool get streamStalled {
    final c = client;
    if (c == null) return false;
    final d = c.diagnostics();
    return d.streaming && (d.sinceMessage?.inMilliseconds ?? 1 << 30) > 3000;
  }

  // ---------------------------------------------------------------------------------------------
  // console

  /// One command character (or 0xNN). Bootloader, DFU and calibration are blocked here.
  Future<void> consoleSend(String raw) async {
    raw = raw.trim();
    if (raw.isEmpty) return;
    final hex = RegExp(r'^0x[0-9a-fA-F]{1,2}$');
    final ch = hex.hasMatch(raw) ? int.parse(raw.substring(2), radix: 16) : raw.codeUnitAt(0);
    final c = String.fromCharCode(ch);
    if ('BDC'.contains(c)) {
      log("'$c' (bootloader, DFU, calibration) is blocked here: use tools/striso.py", LogKind.err);
      return;
    }
    if (c == 'Q') {
      log('Q needs a binary payload: use the knobs', LogKind.err);
      return;
    }
    final cl = client;
    if (cl == null) {
      log('not connected', LogKind.err);
      return;
    }
    log('> Stc${ch >= 0x80 ? '\\x${ch.toRadixString(16)}' : c}');
    final lines = await cl.raw(ch);
    for (final l in lines) {
      log(l, LogKind.out);
    }
    if (lines.isEmpty) log('(no reply)');
    // V and s stop the stream; voice changes need a refresh
    if (identical(client, cl) && (c == 'V' || c == 's')) unawaited(cl.startStream().catchError((_) {}));
    if (identical(client, cl) && ch >= 0x80) await syncVoice();
  }

  // demo play -------------------------------------------------------------------------------------

  bool get playable => playBoard != null;
}
