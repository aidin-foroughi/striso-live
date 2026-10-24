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

import 'app_log.dart';
import 'harmony_tracker.dart';
import 'morph_model.dart';
import 'store.dart';

/// Milliseconds since the app started: the one clock for the live state and the animation.
final Stopwatch _appClock = Stopwatch()..start();
double clockMs() => _appClock.elapsedMicroseconds / 1000;

/// USB as the app sees it (the libusb service in the app, nothing in tests).
abstract class UsbBackend {
  Future<({bool present, String where})> probe();
  Transport transport();
  Future<void> dispose();
}

/// A change notifier anyone may ring.
class Pulse extends ChangeNotifier {
  void ping() => notifyListeners();
}

enum ConnMode { none, usb, demo }

enum Dot { off, on, demo, busy }

enum InviteState { idle, connecting, reconnect }

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

class ParamSet {
  final String name;
  final List<Param> params;
  final bool missing, complete;
  const ParamSet(this.name, this.params, {this.missing = false, this.complete = true});
  static const empty = ParamSet('', []);
}

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
  const AppOptions({this.demo = false, this.noUsb = false, this.noAudio = false, this.fakeSave, this.reducedMotion = false});

  static AppOptions parse(List<String> args) {
    String? fake;
    for (final a in args) {
      if (a == '--fake-save') fake = 'ok';
      if (a.startsWith('--fake-save=')) fake = a.substring(12);
    }
    return AppOptions(
      demo: args.contains('--demo'),
      noUsb: args.contains('--no-usb'),
      noAudio: args.contains('--no-audio'),
      fakeSave: fake,
      reducedMotion: args.contains('--reduced-motion'),
    );
  }
}

const allTargets = [0, 1, 2, 3];
const targetNames = ['voice', 'effect', 'touch', 'key'];
const _intentKey = 'usbIntent';
const reconnectDelay = Duration(milliseconds: 4000), _reconnectRetry = Duration(milliseconds: 3000), _reconnectWindow = Duration(milliseconds: 30000);

class AppController extends ChangeNotifier implements MorphHost {
  final AppOptions options;
  final Store store;
  final UsbBackend? usb;
  final String backupDir;

  /// Through PC: the Striso's USB audio through the computer, and recording it.
  late final ThroughPc audio;

  /// Through PC's state and choices changed (toggle, status line, pickers).
  final audioState = Pulse();

  /// About 20 times a second while audio runs: levels, latency, the recording's time.
  final audioLevels = Pulse();

  final live = LiveState();
  final history = History();
  late final harmony = HarmonyTracker(live);
  late final morph = MorphModel(this);

  /// Parameter values changed (knobs, sliders, readouts).
  final values = Pulse();

  /// 120 ms readouts: stats, probe, diagnostics, live meter text.
  final stats = Pulse();

  final toasts = ValueNotifier<List<ToastMsg>>(const []);

  // connection
  StrisoClient? client;
  Transport? _transport;
  ConnMode mode = ConnMode.none;
  bool connecting = false, saving = false, listsLoading = false;
  VersionInfo? version;
  Dot dot = Dot.off;
  String status = 'Not connected';
  Banner? banner;
  InviteState invite = InviteState.idle;
  String inviteText = '';
  Future<void>? listsReady;
  Map<String, int>? trace;
  Stopwatch? _traceClock;

  // voices and parameters
  List<VoiceEntry> voices = const [];
  int current = -1;
  String voiceName = '';
  final Map<int, ParamSet> params = {for (final t in allTargets) t: ParamSet.empty};
  final Map<int, Set<String>> locks = {0: <String>{}, 1: <String>{}};
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
  final Map<String, int> _remembered = {};
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

  Timer? _reconnectTimer, _presenceTimer, _syncTimer;
  bool _reconnectPending = false;
  DateTime _reconnectDeadline = DateTime.now();
  int _reconnectTries = 0;
  bool? _lastPresent;
  bool _disposed = false;
  int _toastId = 0;

  AppController({required this.options, required this.store, this.usb, AudioBackend? audioBackend, String? backupDir})
    : backupDir = backupDir ?? '${appSupportDir()}${Platform.pathSeparator}backups' {
    _loadPrefs();
    final audioJson = store.raw('audio');
    final repaired = AudioPrefs.repairNote(audioJson);
    audio = ThroughPc(
      backend: audioBackend,
      prefs: AudioPrefs.fromJson(audioJson),
      boardOnUsb: () => (client != null && mode == ConnMode.usb) || _lastPresent == true,
      onPrefs: (p) => store.set('audio', p.toJson()),
      log: (s) => log(s),
    );
    if (repaired != null) {
      log(repaired);
      store.set('audio', audio.prefs.toJson()); // once: saved as version 3
    }
    audio.addListener(audioState.ping);
    audio.addLevelListener(audioLevels.ping);
    live.pressListeners.add((id, _) {
      if (eqFollow) eqSelect(id);
    });
    live.releaseListeners.add((_, _) => values.ping());
    live.controlListeners.add((id, down, before) {
      // the settings button is how voices and tunings change on the instrument: check after it is released
      if (id == Idc.alt && !down && before) {
        Timer(const Duration(milliseconds: 350), () {
          syncVoice();
          refreshTuning();
        });
      }
    });
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

  String? get intent => store.get<String>(_intentKey);
  void _setIntent(String v) => store.set(_intentKey, v);

  /// Starts presence polling and, when the user left the board connected, connects. Through PC
  /// starts too (it plays at once when it was left on).
  Future<void> start() async {
    audio.start();
    if (options.demo) {
      await connectDemo();
      return;
    }
    if (usb == null || options.noUsb) return;
    final p = await _probe();
    _lastPresent = p;
    if (p && intent == 'connected') {
      log('Striso found at start: connecting');
      unawaited(_connectFound(quiet: true));
    } else if (p && intent == 'off') {
      _setStatus(Dot.off, 'Disconnected: click Connect to use the Striso');
    }
    _presenceTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _syncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (client != null && !connecting) syncVoice();
    });
  }

  Future<bool> _probe() async {
    try {
      return (await usb!.probe()).present;
    } catch (e) {
      log('USB: $e', LogKind.err);
      return false;
    }
  }

  bool _polling = false;
  Future<void> _poll() async {
    if (_polling || _disposed || client != null || connecting || saving) return;
    _polling = true;
    try {
      final p = await _probe();
      final was = _lastPresent;
      _lastPresent = p;
      if (was != p) notifyListeners();
      if (p && was == false) {
        if (intent != 'connected') {
          log('Striso plugged in; not connecting (disconnected by the user: click Connect)');
        } else {
          _scheduleReconnect('Striso plugged in');
        }
      } else if (!p && was == true && _reconnectPending) {
        _cancelReconnect();
        _setStatus(Dot.off, 'Unplugged');
      }
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _presenceTimer?.cancel();
    _syncTimer?.cancel();
    _editsTimer?.cancel();
    _tuningPoll?.cancel();
    audio.dispose();
    final c = client;
    client = null;
    if (c != null) unawaited(c.disconnect().catchError((_) {}));
    unawaited(usb?.dispose());
    super.dispose();
  }

  /// Let go of the board before the window closes.
  Future<void> shutdown() async {
    audio.dispose(); // finishes a recording's file, closes the audio devices
    final c = client;
    client = null;
    if (c != null) {
      try {
        await c.disconnect().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await usb?.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // status, banner, toasts, log

  void log(String text, [LogKind kind = LogKind.info]) => appLog.add(text, kind);

  void _setStatus(Dot d, String s) {
    dot = d;
    status = s;
    notifyListeners();
  }

  void showBanner(String text, {bool info = false}) {
    banner = Banner(text, info: info);
    log(text, LogKind.err);
    notifyListeners();
  }

  void hideBanner() {
    if (banner == null) return;
    banner = null;
    notifyListeners();
  }

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

  void _setInvite(InviteState s, [String text = '']) {
    invite = s;
    inviteText = text;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------
  // connecting

  bool get reconnectPending => _reconnectPending;

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectPending = false;
    if (!connecting) _setInvite(InviteState.idle);
    notifyListeners();
  }

  void _scheduleReconnect(String why) {
    _cancelReconnect();
    if (saving || intent != 'connected' || client != null || connecting) return;
    _reconnectPending = true;
    _reconnectDeadline = DateTime.now().add(reconnectDelay + _reconnectWindow);
    _reconnectTries = 0;
    final s = reconnectDelay.inMilliseconds ~/ 1000;
    _setInvite(InviteState.reconnect, 'Your Striso is back: connecting in $s s.');
    _setStatus(Dot.busy, 'Striso found, connecting in $s s');
    log('$why: reconnecting in $s s');
    _reconnectTimer = Timer(reconnectDelay, _tryReconnect);
  }

  Future<void> _tryReconnect() async {
    _reconnectTimer = null;
    if (!_reconnectPending || saving || intent != 'connected' || client != null || connecting) return;
    _reconnectTries++;
    final r = await _connectFound(quiet: true);
    if (r == true) {
      _cancelReconnect();
      return;
    }
    if (!_reconnectPending) return; // cancelled meanwhile
    if (r == 'busy' && DateTime.now().add(_reconnectRetry).isBefore(_reconnectDeadline)) {
      _setStatus(Dot.busy, 'Board busy (being updated?)');
      _reconnectTimer = Timer(_reconnectRetry, _tryReconnect);
      return;
    }
    _cancelReconnect();
    if (r == 'busy') {
      _setStatus(Dot.off, 'Board busy: click Connect when it is free');
      log('still busy after $_reconnectTries tries: gave up reconnecting', LogKind.err);
    }
  }

  /// The Connect button: the user wants the board, now.
  Future<void> userConnect() async {
    _cancelReconnect();
    _trace('click', start: true);
    if (usb == null || options.noUsb) {
      showBanner('USB is switched off in this run (--no-usb). Try the demo instead.');
      return;
    }
    _setStatus(Dot.busy, 'Looking for the Striso');
    _setInvite(InviteState.connecting, 'Looking for your Striso…');
    final r = await _connectFound();
    if (r != true && client == null) _setInvite(InviteState.idle);
  }

  /// The Disconnect button (or Cancel while a reconnect waits): stay away until Connect.
  Future<void> userDisconnect() async {
    if (mode == ConnMode.usb || _reconnectPending) _setIntent('off');
    _cancelReconnect();
    await endSession();
  }

  /// The header button: Connect, Disconnect or Cancel.
  Future<void> connectButton() async {
    if (client != null) return mode == ConnMode.usb ? userDisconnect() : endSession();
    if (_reconnectPending) return userDisconnect();
    return userConnect();
  }

  String get connectLabel => client != null ? 'Disconnect' : (_reconnectPending ? 'Cancel' : 'Connect');

  Future<Object> _connectFound({bool quiet = false}) async {
    final p = await _probe();
    if (!p) {
      if (!quiet) {
        _setStatus(Dot.off, 'No Striso found');
        showBanner('No Striso found on USB. Plug it in (and switch it on), then click Connect.');
      }
      return false;
    }
    return startSession(usb!.transport(), ConnMode.usb, quiet: quiet);
  }

  Future<void> connectDemo() async {
    if (connecting) {
      toast('Connecting to the Striso: the demo can wait', 'warn');
      return;
    }
    if (client != null && mode == ConnMode.usb) _setIntent('off'); // leaving the board on purpose
    _cancelReconnect();
    await startSession(MockTransport(), ConnMode.demo);
  }

  MockBoard? get demoBoard {
    final t = _transport;
    return t is MockTransport ? t.board : null;
  }

  /// true when connected; 'busy' when another program holds the board (quiet: no banner).
  Future<Object> startSession(Transport transport, ConnMode m, {bool quiet = false}) async {
    if (connecting) return false;
    if (client != null) await endSession(quiet: true);
    connecting = true;
    hideBanner();
    _setStatus(Dot.busy, m == ConnMode.demo ? 'Starting the demo' : 'Connecting');
    if (m == ConnMode.usb) {
      _setInvite(InviteState.connecting, 'Connecting to your Striso…');
      if (_traceClock == null || _traceClock!.elapsedMilliseconds > 60000) _trace('connect', start: true);
    }
    final c = StrisoClient(transport);
    if (m == ConnMode.usb) c.trace = (l) => _trace(l);
    c.onStream = (src, id, v, n) => live.apply(src, id, v, n, clockMs());
    c.closed.listen((reason) => _onClientClosed(c, reason));
    c.qErrors.listen((e) {
      final list = params[e.target]?.params ?? const <Param>[];
      final p = list.where((q) => q.index == e.index).firstOrNull;
      toast('The board refused ${e.target < targetNames.length ? targetNames[e.target] : e.target} parameter ${p?.name ?? e.index}', 'warn');
      log('Q err ${e.target} ${e.index}', LogKind.err);
    });
    c.text.listen((l) => log(l, LogKind.out));
    c.restreams.listen((q) => log('no stream messages for ${(q / 1000).toStringAsFixed(1)} s while bytes arrive: sent S again', LogKind.err));
    try {
      await c.connect();
    } catch (e) {
      connecting = false;
      final busy = e is UsbError && (e.code == UsbErrorCode.busy || e.code == UsbErrorCode.denied);
      if (quiet && busy) {
        log('board busy: $e');
        notifyListeners();
        return 'busy';
      }
      _setStatus(Dot.off, busy ? 'Board busy' : 'Not connected');
      _setInvite(InviteState.idle);
      showBanner(e is UsbError ? e.message : 'Could not connect: $e');
      return busy ? 'busy' : false;
    }
    client = c;
    _transport = transport;
    mode = m;
    try {
      final v = await c.getVersion();
      if (!c.open) throw UsbError.unplugged;
      if (v == null) {
        showBanner('The Striso did not answer the version request. Check that it runs the Striso firmware, then unplug and replug it.');
      }
      version = v;
      log('connected: ${v?.line ?? 'no version reply'}');
      if (m == ConnMode.usb) _trace('version');
      await refreshVoices();
      if (m == ConnMode.usb) _trace('voice list (${voices.length})');
      unawaited(c.startStream().catchError((_) {}));
    } catch (e) {
      connecting = false;
      if (identical(client, c)) await endSession(quiet: true);
      showBanner(e is UsbError ? e.message : '$e');
      return false;
    }
    connecting = false;
    if (!c.open) return false;
    _setStatus(m == ConnMode.demo ? Dot.demo : Dot.on, m == ConnMode.demo ? 'Demo (simulated Striso)' : 'Connected');
    waveT = clockMs();
    if (m == ConnMode.usb) {
      _setIntent('connected');
      _lastPresent = true;
      _trace('live');
    }
    _setInvite(InviteState.idle);
    // the parameter lists load behind the live view (the load poll waits its turn)
    listsLoading = true;
    if (m == ConnMode.usb) status = 'Connected \u00b7 reading parameters';
    notifyListeners();
    listsReady = refreshParams(allTargets, voiceChanged: true)
        .then((_) async {
          if (m == ConnMode.usb && identical(client, c)) _trace('all lists');
          if (identical(client, c)) _offerRestore();
          if (identical(client, c)) await refreshTuning();
        })
        .whenComplete(() {
          if (identical(client, c)) {
            listsLoading = false;
            if (m == ConnMode.usb) status = 'Connected';
            notifyListeners();
          }
        });
    unawaited(_pollLoad(c));
    unawaited(_pollUsbAudio(c));
    return true;
  }

  Future<void> endSession({bool quiet = false}) async {
    final c = client;
    client = null;
    if (c != null) {
      try {
        await c.disconnect();
      } catch (_) {}
    }
    _resetUi();
    if (!quiet) _setStatus(Dot.off, 'Not connected');
  }

  void _onClientClosed(StrisoClient c, UsbError? reason) {
    if (!identical(client, c)) return;
    client = null;
    _resetUi();
    final auto = mode == ConnMode.usb && intent == 'connected';
    if (reason != null && reason.code == UsbErrorCode.unplugged) {
      _lastPresent = false;
      _setStatus(Dot.off, 'Unplugged');
      showBanner(
        auto ? 'The Striso was unplugged. It reconnects by itself a few seconds after it is back.' : 'The Striso was unplugged.',
        info: true,
      );
    } else if (reason != null) {
      _setStatus(Dot.off, 'Connection lost');
      showBanner(reason.message);
      // still plugged in (a USB error): try again after the delay
      if (auto) _scheduleReconnect('connection lost');
    } else {
      _setStatus(Dot.off, 'Not connected');
    }
  }

  void _resetUi() {
    history.clear();
    live.clear();
    voices = const [];
    current = -1;
    voiceName = '';
    for (final t in allTargets) {
      params[t] = ParamSet.empty;
    }
    morph.load(null);
    version = null;
    load = null;
    loadNa = false;
    loadHist.clear();
    _transport = null;
    tuning = null;
    tuningSupported = null;
    _tuningSuggested = false;
    _tuningHinted = false;
    _scheduleTuningPoll(); // stops it: no client
    harmony.reset();
    notifyListeners();
    values.ping();
  }

  bool get connected => client != null;

  /// The app may send to the board: a session is up (the board over USB, or the demo board) and is
  /// not still being set up. Every control that acts on the board checks this; without it they do
  /// nothing (no pulse, no state change) and say "Connect to switch this from the app".
  bool get canSend => client != null && !connecting;

  /// What a control that sends to the board says while it cannot.
  String get sendHint => connecting ? 'Connecting…' : 'Connect to switch this from the app';

  /// A Striso is on USB (from the presence poll).
  bool get boardPresent => _lastPresent == true;

  /// The connection was lost (unplugged or a USB error), not ended by the user.
  bool get lost => !connected && (status == 'Unplugged' || status == 'Connection lost');
  bool get ledOn => client != null;

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
  }

  /// The voice can also change on the instrument (settings + row 4 keys).
  Future<void> syncVoice() async {
    final c = client;
    if (c == null || connecting) return;
    await _voiceBusy;
    final before = current;
    await refreshVoices();
    if (identical(client, c) && current != before) {
      lastSound = null;
      await refreshParams([0, 1], voiceChanged: true);
      toast('Voice changed on the instrument: $voiceName');
    }
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
        params[t] = const ParamSet('', [], missing: true);
      } else {
        params[t] = ParamSet(r.name, [for (final p in r.params) p..loadValue = p.value], complete: r.complete);
        if (!r.complete) toast('Only ${r.params.length} of ${r.count} ${targetNames[t]} parameters arrived', 'warn');
      }
    }
    if (abOn) {
      abOn = false;
      _abEdits = [];
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

  Param? findParam(int t, String name) => params[t]!.params.where((q) => q.name == name).firstOrNull;

  /// The one place values change: model, board (throttled by the client) and history.
  bool setValue(int t, Param p, double v, {bool record = true, bool send = true}) {
    v = conformValue(p, v);
    if (v == p.value) return false;
    if (record) history.record(t, p.name, p.value, v);
    p.value = v;
    if (send) client?.setParam(t, p.index, v);
    _valuesDirty = true;
    return true;
  }

  bool _valuesDirty = false;

  /// phase: 'begin' | 'change' | 'end'
  void onEdit(int t, Param p, double v, String phase, [String? label, String? key]) {
    if (abOn) {
      abOn = false;
      _abEdits = [];
      notifyListeners();
    }
    if (phase == 'begin') history.begin(label ?? 'Edit', key);
    setValue(t, p, v);
    if (phase == 'end') history.commit();
    _flushValues();
  }

  (bool, bool) _undoState = (false, false);

  void _flushValues() {
    if (!_valuesDirty) return;
    _valuesDirty = false;
    values.ping();
    _rememberEditsSoon();
    final u = (history.canUndo, history.canRedo);
    if (u != _undoState) {
      _undoState = u;
      notifyListeners(); // undo/redo buttons
    }
  }

  void _applyChanges(List<(int, String, double)> changes) {
    for (final (t, name, v) in changes) {
      final p = findParam(t, name);
      if (p != null) setValue(t, p, v, record: false);
    }
  }

  String _lc(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  void undo() {
    final e = history.undo();
    if (e == null) return;
    _applyChanges(e.changes);
    _flushValues();
    notifyListeners();
    toast('Undid ${_lc(e.label)}');
  }

  void redo() {
    final e = history.redo();
    if (e == null) return;
    _applyChanges(e.changes);
    _flushValues();
    notifyListeners();
    toast('Redid ${_lc(e.label)}');
  }

  bool get hasSound => params[0]!.params.isNotEmpty || params[1]!.params.isNotEmpty;

  String mutateScope = '0';
  double mutateAmount = 0.12;

  void setMutateScope(String s) {
    mutateScope = s;
    notifyListeners();
  }

  final _random = math.Random();

  void mutate() {
    final targets = mutateScope == 'both' ? [0, 1] : [int.parse(mutateScope)];
    history.begin('Mutate');
    var n = 0;
    for (final t in targets) {
      for (final (p, v) in mutateValues(params[t]!.params, mutateAmount, _random, locked: locks[t]!)) {
        if (setValue(t, p, v)) n++;
      }
    }
    history.commit();
    _flushValues();
    notifyListeners();
    toast(n > 0 ? 'Mutated $n parameters. Undo brings them back.' : 'Nothing to mutate', n > 0 ? '' : 'warn');
  }

  void resetAll() {
    history.begin('Reset all');
    for (final t in soundTargets) {
      for (final p in params[t]!.params) {
        setValue(t, p, p.loadValue);
      }
    }
    history.commit();
    _flushValues();
    notifyListeners();
  }

  void toggleLock(int t, Param p) {
    final set = locks[t]!;
    if (!set.remove(p.name)) set.add(p.name);
    toast(set.contains(p.name) ? '${p.name} locked against Mutate' : '${p.name} unlocked');
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
    alive: () => identical(client, c) && !_disposed,
    paused: () => connecting || saving,
    log: (s) => log(s),
    onTarget: audioState.ping,
  ).run();

  Future<void> _pollLoad(StrisoClient c) async {
    while (identical(client, c) && !_disposed) {
      if (!connecting) {
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
      }
      await Future<void>.delayed(const Duration(seconds: 1));
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
  bool _tuningSuggested = false, _tuningHinted = false, _tuningBusy = false;
  Timer? _tuningPoll;

  /// Pitch labels want the tuning: N is asked for on connect, after the Settings button is
  /// released, and every 2 s while pitch or cents labels show (a cheap one-line poll).
  bool get _wantsTuningPoll => client != null && (names == Names.pitch || names == Names.cents) && tuningSupported != false;

  void _scheduleTuningPoll() {
    _tuningPoll?.cancel();
    _tuningPoll = null;
    if (!_wantsTuningPoll) return;
    _tuningPoll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_wantsTuningPoll) {
        _tuningPoll?.cancel();
        _tuningPoll = null;
        return;
      }
      if (!connecting && !saving) refreshTuning();
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
        if (tuningSupported != true) log('tuning: ${t.naming.name}${t.referenceText != null ? ', ${t.referenceText}' : ''}');
        tuningSupported = true;
        final was = tuning?.naming.name;
        tuning = t;
        if (!t.isPlain12 && !_tuningSuggested && names != Names.pitch && names != Names.cents) {
          _tuningSuggested = true;
          toastAction(
            'The Striso plays ${t.naming.name}${t.referenceText != null ? ' at ${t.referenceText}' : ''}',
            'Pitch labels',
            () => setNames(Names.pitch),
          );
        } else if (was != null && was != t.naming.name) {
          toast('Tuning: ${t.naming.name}');
        }
      }
      notifyListeners();
    } finally {
      _tuningBusy = false;
      _scheduleTuningPoll();
    }
  }

  /// The tuning's names: from the N reply, else 12-TET (the layout's assumption).
  String get tuningName => tuning?.naming.name ?? '12-TET';
  String get tuningShort => tuning?.naming.short ?? '12TET';

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
    final b = demoBoard;
    if (b == null) return;
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

  void resetTranspose() {
    live.resetTranspose();
    notifyListeners();
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
    if (client == null || (mode != ConnMode.usb && options.fakeSave == null)) {
      toast(mode == ConnMode.demo ? 'The demo keeps its settings until you restart it' : 'Connect the Striso first', 'warn');
      return 'not connected';
    }
    if (params[2]!.params.isEmpty && params[3]!.params.isEmpty) {
      toast('This firmware has no touch settings to save', 'warn');
      return 'no settings';
    }
    return null;
  }

  Future<void> doSave() async {
    final c = client;
    if (c == null) return;
    saving = true;
    _cancelReconnect();
    notifyListeners();
    final demo = mode == ConnMode.demo;
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
    await endSession(quiet: true);
    _setStatus(Dot.busy, 'Saving to the Striso');
    final res = await saveTouch(values, backupDir: backupDir, progress: (t) => _setSaveStatus(t), fake: options.fakeSave);
    saving = false;
    log('save: ${res.ok ? 'ok' : 'failed'}: ${res.message}', res.ok ? LogKind.info : LogKind.err);
    _setSaveStatus(res.ok ? 'Saved. Reconnecting…' : 'Saving failed. Reconnecting…', res.ok ? '' : 'err');
    final back = demo
        ? (await startSession(MockTransport(board: MockBoard(config: _fakeConfig(values))), ConnMode.demo)) == true
        : await _reconnectAfterSave();
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

  MockConfig _fakeConfig(TouchValues v) => MockConfig([for (final (_, x) in v.touch) x], [for (final (_, x) in v.keys) x]);

  Future<bool> _reconnectAfterSave() async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 40) && !_disposed) {
      if (client != null) break;
      if (!connecting && usb != null && await _probe()) {
        if ((await startSession(usb!.transport(), ConnMode.usb, quiet: true)) == true) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    _cancelReconnect();
    return client != null;
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
    for (final f in settingsKeys.values) {
      final e = f.engine;
      if (e == null) continue;
      final list = voices.where((v) => v.engine == e).toList();
      final at = list.indexWhere((v) => v.index == current);
      if (at >= 0) _remembered[e] = at; // like remembered[] in config_voice
      out[e] = SettingsVoice(list.length, at >= 0, at >= 0 ? (list[at].preset ?? '') : '', list);
    }
    return out;
  }

  /// A click on a key while the overlay shows: select it; a voice key picks the voice like the
  /// Striso does. Returns true when the click was taken.
  bool settingsClick(int id) {
    if (!settingsOn) return false;
    final f = settingsKeys[id];
    // a key that acts on the board does nothing at all without one: no selection, no pulse
    if (f != null && (f.engine != null || f.switchable) && !canSend) return true;
    settingsSelected = id;
    if (f?.engine != null) {
      final a = voiceKeyAction(voices, current, f!.engine!, _remembered);
      if (a == null) {
        toast('This firmware has no ${f.engine} voice', 'warn');
      } else {
        selectVoice(a.index);
      }
    } else if (f != null && f.switchable) {
      unawaited(pressSettingsKey(id));
    }
    notifyListeners();
    return true;
  }

  /// A switch key of the settings overlay, pressed over USB (StcK): the led pulses, the board
  /// answers, and what it changed is read again (the tuning; the touch settings and voice for a
  /// settings preset). Firmware without K gets a one-time hint.
  Future<bool> pressSettingsKey(int id) async {
    final c = client;
    final f = settingsKeys[id];
    if (c == null || !canSend || f == null || !f.switchable) return false;
    ledPulseT = clockMs();
    notifyListeners();
    final r = await c.pressSettingsKey(id);
    if (!identical(c, client)) return false;
    if (r == null) {
      if (!_tuningHinted) {
        _tuningHinted = true;
        toast("This firmware can't switch tunings from the app yet. Use Settings + the key on the instrument.", 'warn');
      }
      log('K $id: no reply', LogKind.err);
      return false;
    }
    if (!r.ok) {
      toast('The board refused: ${f.title}', 'warn');
      log('K err $id', LogKind.err);
      return false;
    }
    log('K ok $id: ${f.title}');
    if (f.group == SettingsGroup.tuning) {
      await refreshTuning();
    } else if (f.group == SettingsGroup.preset) {
      await refreshParams([2]);
      await syncVoice();
      await refreshTuning();
      toast('Loaded settings preset ${presetKeyIds.indexOf(id) + 1}');
    } else if (f.group == SettingsGroup.midi) {
      toast(f.title);
    } else if (id == 63) {
      toast('All notes off');
    }
    notifyListeners();
    return true;
  }

  /// When the indicator led was last made to pulse by an app action (ms, app clock).
  double ledPulseT = -1e9;

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

  /// The engine buttons: the eight of the Striso's voice keys in key order with their led
  /// colours, then any other engine this firmware lists.
  List<EngineButton> engines() {
    final out = <EngineButton>[];
    final seen = <String>{};
    for (final e in voiceKeys.values) {
      final (engine, led) = e;
      if (!seen.add(engine)) continue;
      out.add(EngineButton(engine, ledColor(led), voices.where((v) => v.engine == engine).length));
    }
    var k = 0;
    for (final v in voices) {
      if (seen.add(v.engine)) {
        final hue = engineInfo(v.engine, k++).hue;
        out.add(EngineButton(v.engine, HSLColorInt.of(hue), voices.where((x) => x.engine == v.engine).length));
      }
    }
    return out;
  }

  String get currentEngine => voices.where((v) => v.index == current).firstOrNull?.engine ?? (voiceName.isEmpty ? '' : voiceName.split(':').first);

  /// The engine button: like a voice key on the Striso, the engine with the preset it had last.
  void selectEngine(String engine) {
    if (!canSend) {
      toast(connecting ? 'Connecting…' : 'Connect to switch voices', 'warn');
      return;
    }
    settingsVoices(); // remembers the current preset per engine
    final a = voiceKeyAction(voices, current, engine, _remembered, 0);
    if (a == null) {
      toast('This firmware has no ${engineInfo(engine).label} voice', 'warn');
      return;
    }
    if (a.index != current) selectVoice(a.index);
  }

  /// About eight knobs that matter most for the current voice, then the effect amounts.
  List<Param> mainKnobs() => heroKnobs(voiceName, params[0]!.params);
  List<Param> mainFx() => heroFx(params[1]!.params);

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
  // A/B: the preset's values (A) against the edits (B), without touching the history

  bool abOn = false;
  List<(int, Param, double)> _abEdits = [];

  bool get edited => soundTargets.any((t) => params[t]!.params.any((p) => p.value != p.loadValue));

  void setAB(bool on) {
    if (on == abOn || client == null) return;
    if (on) {
      _abEdits = [
        for (final t in soundTargets)
          for (final p in params[t]!.params)
            if (p.value != p.loadValue) (t, p, p.value),
      ];
      if (_abEdits.isEmpty) {
        toast('Nothing edited yet: A and B are the same');
        return;
      }
      abOn = true;
      for (final (t, p, _) in _abEdits) {
        setValue(t, p, p.loadValue, record: false);
      }
    } else {
      abOn = false;
      for (final (t, p, v) in _abEdits) {
        setValue(t, p, v, record: false);
      }
      _abEdits = [];
    }
    _flushValues();
    notifyListeners();
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

  bool get playable => mode == ConnMode.demo && demoBoard != null;
}
