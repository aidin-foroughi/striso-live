// Striso Live's state and behaviour: connection (with the reconnect rules), voices, parameters
// with undo, mutate and morph, user presets, synth load, key and harmony, the key equalizer,
// saving touch settings to the board, the settings overlay and the console. The widgets only
// show this and call into it. Port of tools/app/js/app.js.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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

enum Names { octave, letters, degrees, solfege, off }

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
  const ToastMsg(this.id, this.text, this.kind);
}

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
  final bool demo, noUsb;
  final String? fakeSave; // null, 'ok' or 'fail'
  final bool reducedMotion;
  const AppOptions({this.demo = false, this.noUsb = false, this.fakeSave, this.reducedMotion = false});

  static AppOptions parse(List<String> args) {
    String? fake;
    for (final a in args) {
      if (a == '--fake-save') fake = 'ok';
      if (a.startsWith('--fake-save=')) fake = a.substring(12);
    }
    return AppOptions(
      demo: args.contains('--demo'),
      noUsb: args.contains('--no-usb'),
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

  AppController({required this.options, required this.store, this.usb, String? backupDir})
    : backupDir = backupDir ?? '${appSupportDir()}${Platform.pathSeparator}backups' {
    _loadPrefs();
    live.pressListeners.add((id, _) {
      if (eqFollow) eqSelect(id);
    });
    live.releaseListeners.add((_, _) => values.ping());
    live.controlListeners.add((id, down, before) {
      // the settings button is how voices change on the instrument: check after it is released
      if (id == Idc.alt && !down && before) Timer(const Duration(milliseconds: 350), syncVoice);
    });
  }

  // ---------------------------------------------------------------------------------------------
  // lifecycle

  void _loadPrefs() {
    final n = store.get<String>('names');
    names = Names.values.firstWhere((x) => x.name == n, orElse: () => Names.octave);
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

  /// Starts presence polling and, when the user left the board connected, connects.
  Future<void> start() async {
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
    final c = client;
    client = null;
    if (c != null) unawaited(c.disconnect().catchError((_) {}));
    unawaited(usb?.dispose());
    super.dispose();
  }

  /// Let go of the board before the window closes.
  Future<void> shutdown() async {
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

  void toast(String text, [String kind = '']) {
    final t = ToastMsg(++_toastId, text, kind);
    var l = [...toasts.value, t];
    if (l.length > 4) l = l.sublist(l.length - 4);
    toasts.value = l;
    Timer(Duration(milliseconds: kind == 'error' ? 6000 : 2600), () {
      if (_disposed) return;
      toasts.value = toasts.value.where((x) => x.id != t.id).toList();
    });
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
    notifyListeners();
    listsReady = refreshParams(allTargets, voiceChanged: true)
        .then((_) {
          if (m == ConnMode.usb && identical(client, c)) _trace('all lists');
        })
        .whenComplete(() {
          if (identical(client, c)) {
            listsLoading = false;
            notifyListeners();
          }
        });
    unawaited(_pollLoad(c));
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
    harmony.reset();
    notifyListeners();
    values.ping();
  }

  bool get connected => client != null;
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
    if (c == null || n == current) return;
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
    settingsSelected = id;
    final f = settingsKeys[id];
    if (f?.engine != null) {
      final a = voiceKeyAction(voices, current, f!.engine!, _remembered);
      if (client == null) {
        toast('Connect to switch voices', 'warn');
      } else if (a == null) {
        toast('This firmware has no ${f.engine} voice', 'warn');
      } else {
        selectVoice(a.index);
      }
    }
    notifyListeners();
    return true;
  }

  /// A click on a key on the board (not in demo play).
  bool boardSelect(int id) {
    if (settingsClick(id)) return true;
    eqSelect(id);
    return false;
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
