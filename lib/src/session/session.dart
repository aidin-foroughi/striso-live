// The session: drives the state machine, opens the mode's Board, keeps it (lost, reboot,
// reconnect) and ends everything on Disconnect (docs/architecture.md). The domain logic above it
// (voices, parameters, tuning) gets the board through [SessionHost] and never touches USB, the
// virtual library or the timers here.

import 'dart:async';

import 'package:striso_core/striso_core.dart';

import '../store.dart';
import 'board.dart';
import 'resources.dart';
import 'session_machine.dart';

/// USB as the app sees it (the libusb service in the app, a fake in tests).
abstract class UsbBackend {
  Future<({bool present, String where})> probe();
  Transport transport();
  Future<void> dispose();
}

/// Where the virtual Striso comes from (the striso_virtual library, or the Dart mock in widget
/// tests). It keeps one instrument across a reboot (Save, a reset) and lets it go on [stop].
abstract class VirtualRuntime {
  /// A Board for the instrument: the running one again (after a reboot), else a new one. Throws
  /// [VirtualError] when the library is missing or refused.
  Future<Board> open();

  /// The instrument may restart by itself (a reset): true once it is back on its USB.
  Future<bool> waitBack();

  /// The instrument and everything it holds (its output source, MIDI) go.
  Future<void> stop();
}

class VirtualError implements Exception {
  final String message;
  const VirtualError(this.message);
  @override
  String toString() => message;
}

/// What the session asks of the app.
abstract class SessionHost {
  void note(String text, {bool error = false});
  void say(String text, {bool info = false});
  void clearBanner();

  /// The board answers: read what the UI needs (version, capabilities, voices). Null when it may
  /// go live, else why not.
  Future<FailEv?> boardUp(Board board, bool Function() current);

  /// The board is live: start what keeps the UI in step (the host's pollers go through
  /// [Session.every]).
  void boardLive(Board board);

  /// The board is gone (any reason): forget everything it said.
  void boardDown();

  /// The state changed.
  void sessionChanged();

  /// What runs changed (the status shows it; nothing to route).
  void resourcesChanged();
}

const reconnectDelay = Duration(milliseconds: 4000);
const _busyRetry = Duration(milliseconds: 3000), _busyWindow = Duration(milliseconds: 30000);
const _intentKey = 'usbIntent', _virtualKey = 'virtualOn';

class Session {
  final SessionMachine machine = SessionMachine();
  final Resources resources = Resources();
  final SessionHost host;
  final Store store;
  final UsbBackend? usb;
  final VirtualRuntime? virtual;
  final DateTime Function() now;

  Board? _board;
  bool? lastPresent;
  Timer? _presence, _due;
  DateTime? _busyUntil;
  final _timers = <String, Timer>{};
  bool _polling = false, _disposed = false;
  int _gen = 0; // a new one for every board

  Session({required this.host, required this.store, this.usb, this.virtual, DateTime Function()? clock}) : now = clock ?? DateTime.now {
    machine.addListener((t) {
      if (!t.accepted) {
        host.note('session: refused ${t.refused}');
        return;
      }
      if (t.from != t.to) host.note('session: ${t.from} -> ${t.to}');
      _schedulePresence();
      host.sessionChanged();
    });
    resources.addListener(host.resourcesChanged);
  }

  SessionState get state => machine.state;
  Board? get board => _board;

  /// The console of the board being connected or live.
  StrisoClient? get client => _board?.client;
  Mode? get mode => state.mode;

  /// What the user left the Striso as: 'connected', 'off' or null (never chosen).
  String? get intent => store.get<String>(_intentKey);
  void setIntent(String v) => store.set(_intentKey, v);
  bool get virtualWanted => store.get<bool>(_virtualKey) ?? false;

  bool get waiting => state is Waiting;

  // -------------------------------------------------------------------------------------- start

  /// At start: Virtual again when it was left on, else the Striso when it is on USB, unless the
  /// user let go of it (Disconnect) the last time.
  Future<void> start({bool virtualFirst = false}) async {
    if (virtualFirst || (virtualWanted && virtual != null)) {
      await connect(Mode.virtual);
      return;
    }
    if (usb == null) return;
    final p = await _probe();
    lastPresent = p;
    if (state is! Idle) return; // something started meanwhile (a click)
    if (p && intent != 'off') {
      host.note('Striso found at start: connecting');
      unawaited(connect(Mode.striso, quiet: true));
      return;
    }
    if (intent == 'off') {
      machine.on(const DisconnectEv(IdleWhy.user)); // the status says how to come back
    }
    _schedulePresence();
    host.sessionChanged();
  }

  Future<bool> _probe() async {
    try {
      return (await usb!.probe()).present;
    } catch (e) {
      host.note('USB: $e', error: true);
      return false;
    }
  }

  // ------------------------------------------------------------------------------ presence poll

  /// The presence poll runs only while nothing plays and it serves something: a Striso that
  /// appears connects by itself (docs/flows.md 4). Never after Disconnect (the user let go of the
  /// board), never while a session runs.
  bool get _wantsPresence {
    if (_disposed || usb == null) return false;
    final s = state;
    if (s is! Idle && !(s is Failed && s.mode == Mode.striso)) return false;
    if (s is Idle && (s.why == IdleWhy.user || s.why == IdleWhy.modeSwitch)) return false;
    return intent != 'off';
  }

  void _schedulePresence() {
    final want = _wantsPresence;
    if (want && _presence == null) {
      _presence = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
      resources.up(Res.presence, 'every 1 s');
    } else if (!want && _presence != null) {
      _presence!.cancel();
      _presence = null;
      resources.down(Res.presence);
    }
  }

  Future<void> _poll() async {
    if (_polling || !_wantsPresence) return;
    _polling = true;
    try {
      final p = await _probe();
      final was = lastPresent;
      lastPresent = p;
      if (was != p) host.sessionChanged();
      if (!_wantsPresence) return;
      if (p && was == false) _wait('Striso plugged in', reconnectDelay);
    } finally {
      _polling = false;
    }
  }

  /// A connect of the Striso is due after [after] (Waiting).
  void _wait(String why, Duration after) {
    _due?.cancel();
    _busyUntil ??= now().add(after + _busyWindow);
    if (!machine.on(WaitEv(Mode.striso, why, now().add(after))).accepted) return;
    host.note('$why: connecting in ${after.inMilliseconds / 1000} s');
    resources.up(Res.reconnect, why);
    _due = Timer(after, () {
      _due = null;
      resources.down(Res.reconnect);
      if (state is Waiting) unawaited(connect(Mode.striso, quiet: true));
    });
  }

  void _cancelDue() {
    _due?.cancel();
    _due = null;
    resources.down(Res.reconnect);
  }

  // ----------------------------------------------------------------------------------- connect

  /// Connects [m]; another mode running is ended first (a full teardown). Returns true when live.
  Future<bool> connect(Mode m, {bool quiet = false}) async {
    final s = state;
    if (s is Connecting) return false;
    if (s.live && s.mode == m) return true;
    if (s.live || s is Rebooting && s.mode != m) await disconnect(why: IdleWhy.modeSwitch);
    if (!quiet) _busyUntil = null;
    final reboot = s is Rebooting ? s.why : null;
    if (!machine.on(ConnectEv(m, quiet: quiet)).accepted) return false;
    // a reboot's connect that does not get the board yet stays in the reboot (comeBack tries again)
    bool fail(FailEv f) {
      if (reboot != null) {
        machine.on(RebootEv(reboot));
        return false;
      }
      return _fail(f);
    }

    _cancelDue();
    host.clearBanner();
    final gen = ++_gen;
    bool current() => gen == _gen && !_disposed;

    // the board
    Board b;
    if (m == Mode.striso) {
      if (usb == null) {
        return fail(const FailEv(FailKind.noUsb, 'USB is switched off in this run (--no-usb). Play the virtual Striso instead.'));
      }
      machine.on(const StepEv('looking for the Striso'));
      final p = await _probe();
      if (!current()) return false;
      lastPresent = p;
      if (!p) {
        if (quiet && reboot == null) {
          machine.on(const LostEv());
          return false;
        }
        return fail(const FailEv(FailKind.notFound, 'No Striso on USB.'));
      }
      b = StrisoBoard(usb!.transport());
    } else {
      final v = virtual;
      if (v == null) return fail(const FailEv(FailKind.library, 'The virtual Striso is not available in this run.'));
      machine.on(const StepEv('starting the virtual Striso'));
      try {
        b = await v.open();
      } catch (e) {
        return fail(FailEv(FailKind.library, '$e'));
      }
      if (!current()) {
        await v.stop();
        return false;
      }
    }

    // the console
    machine.on(const StepEv('opening'));
    try {
      await b.open();
    } catch (e) {
      if (!current()) return false;
      final busy = e is UsbError && (e.code == UsbErrorCode.busy || e.code == UsbErrorCode.denied);
      if (busy && reboot != null) return fail(FailEv(FailKind.busy, '$e'));
      if (busy && quiet && _busyUntil != null && now().add(_busyRetry).isBefore(_busyUntil!)) {
        host.note('board busy: $e');
        _wait('Board busy (being updated?)', _busyRetry);
        return false;
      }
      _busyUntil = null;
      final kind = busy ? FailKind.busy : (e is UsbError && e.code == UsbErrorCode.noDriver ? FailKind.noDriver : FailKind.other);
      final msg = e is UsbError ? e.message : 'Could not connect: $e';
      if (reboot != null) return fail(FailEv(kind, msg));
      if (m == Mode.virtual) await virtual?.stop();
      return _fail(FailEv(kind, msg));
    }
    _busyUntil = null;
    if (!current()) {
      await b.close();
      return false;
    }
    _board = b;
    resources.up(Res.console, b.label);
    b.client.closed.listen((reason) => _onClosed(b, reason));

    machine.on(const StepEv('reading the board'));
    FailEv? f;
    try {
      f = await host.boardUp(b, () => current() && identical(_board, b));
    } catch (e) {
      f = FailEv(FailKind.other, e is UsbError ? e.message : '$e');
    }
    if (!current() || !identical(_board, b)) return false;
    if (f != null || !b.client.open) {
      await _end();
      return fail(f ?? const FailEv(FailKind.other, 'The board went away while connecting.'));
    }
    if (!machine.on(const ReadyEv()).accepted) return false;
    if (m == Mode.striso) {
      setIntent('connected');
      lastPresent = true;
    }
    store.set(_virtualKey, m == Mode.virtual);
    host.boardLive(b);
    return true;
  }

  /// The session failed: the state carries the kind and the message; the host shows the problem
  /// and its fix from the state (docs/flows.md 7).
  bool _fail(FailEv f) {
    machine.on(f);
    return false;
  }

  // -------------------------------------------------------------------------------- disconnect

  /// Ends the whole session: the console, the stream, every poller, the virtual instrument and its
  /// sound. [why] user (Disconnect): the Striso stays away until it is connected again by hand;
  /// stopped (Stop, Virtual): nothing plays, the Striso's standing is untouched.
  Future<void> disconnect({IdleWhy why = IdleWhy.user}) async {
    if (why == IdleWhy.user) {
      if (state.mode == Mode.striso || state is Waiting) setIntent('off');
      store.set(_virtualKey, false);
    } else if (why == IdleWhy.stopped) {
      store.set(_virtualKey, false);
    }
    _cancelDue();
    _busyUntil = null;
    _gen++;
    machine.on(DisconnectEv(why));
    await _end();
    if (virtual != null) await virtual!.stop();
    resources.down(Res.virtualBoard);
    host.sessionChanged();
  }

  /// Lets go of the board: pollers, the console. The state is the caller's.
  Future<void> _end() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    for (final n in _timers.keys.toList()) {
      resources.down(n);
    }
    _timers.clear();
    final b = _board;
    _board = null;
    host.boardDown();
    if (b != null) await b.close();
    resources.down(Res.console);
    resources.down(Res.stream);
  }

  void _onClosed(Board b, UsbError? reason) {
    if (!identical(_board, b) || reason == null) return;
    final s = state;
    unawaited(_end());
    if (s is Rebooting) return; // expected
    final unplugged = reason.code == UsbErrorCode.unplugged;
    final auto = b.mode == Mode.striso && intent == 'connected';
    if (b.mode == Mode.striso) {
      if (unplugged) lastPresent = false;
      machine.on(LostEv(unplugged: unplugged, note: reason.message));
      if (unplugged) {
        host.say(auto ? 'The Striso was unplugged. It reconnects by itself a few seconds after it is back.' : 'The Striso was unplugged.', info: true);
      } else {
        host.say(reason.message);
        if (auto) _wait('connection lost', reconnectDelay);
      }
    } else {
      // the virtual board restarted (a reset): it comes back by itself
      machine.on(const RebootEv('reset'));
      unawaited(_comeBackVirtual());
    }
  }

  Future<void> _comeBackVirtual() async {
    final v = virtual;
    if (v == null) return;
    if (await v.waitBack() && state is Rebooting) {
      await connect(Mode.virtual, quiet: true);
    } else if (state is Rebooting) {
      _fail(const FailEv(FailKind.other, 'The virtual Striso did not come back after its restart.'));
    }
  }

  // ------------------------------------------------------------------------------------ reboots

  /// The board goes away on purpose (Save to Striso): the session waits in Rebooting and lets go
  /// of the console; [comeBack] connects again.
  Future<void> beginReboot(String why) async {
    machine.on(RebootEv(why));
    _cancelDue();
    _gen++;
    await _end();
  }

  /// After a reboot: the same mode again (the Striso: up to 40 s for it to be back on USB).
  Future<bool> comeBack() async {
    final s = state;
    if (s is! Rebooting) return false;
    if (s.mode == Mode.virtual) {
      if (!await (virtual?.waitBack() ?? Future.value(false))) {
        return _fail(const FailEv(FailKind.other, 'The virtual Striso did not come back after its restart.'));
      }
      return connect(Mode.virtual, quiet: true);
    }
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 40) && !_disposed && state is Rebooting) {
      if (usb != null && await _probe()) {
        if (await connect(Mode.striso, quiet: true)) return true;
        if (state is! Rebooting) return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (state is Rebooting) _fail(const FailEv(FailKind.notFound, 'Saved, but the Striso did not come back.'));
    return false;
  }

  // ----------------------------------------------------------------------------------- pollers

  /// A periodic job of this board's session, named for the resources: it ends with the session.
  void every(String name, Duration d, void Function() f, {String what = ''}) {
    _timers.remove(name)?.cancel();
    _timers[name] = Timer.periodic(d, (_) => f());
    resources.up(name, what.isEmpty ? 'every ${d.inMilliseconds} ms' : what);
  }

  void stopEvery(String name) {
    _timers.remove(name)?.cancel();
    resources.down(name);
  }

  bool runs(String name) => _timers.containsKey(name);

  // ----------------------------------------------------------------------------------- the end

  Future<void> dispose() async {
    _disposed = true;
    _cancelDue();
    _presence?.cancel();
    _presence = null;
    resources.down(Res.presence);
    _gen++;
    await _end();
    await virtual?.stop();
  }
}
