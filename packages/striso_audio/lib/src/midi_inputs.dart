// Which MIDI inputs play Virtual: the user's choice (a set of device ids, persisted by the
// caller), kept open while started: refreshed every second, a chosen input opened when it is
// there and reopened when it comes back after an unplug, a status per input for the picker and
// the activity for its pip. Pure Dart over MidiBackend (no Flutter); the MIDI itself goes from
// the driver to the sink in the native library and never through here.
import 'dart:async';

import 'midi.dart';

/// What an input is doing, for the picker.
enum MidiInputState {
  /// not chosen
  off,

  /// chosen and open: playing
  open,

  /// chosen, not plugged in (or gone)
  notConnected,

  /// chosen, held by another program (Windows)
  inUse,

  /// chosen, would not open (see [MidiInputStatus.text])
  error,

  /// chosen, MIDI not started (stopped, or no MIDI system)
  stopped,
}

class MidiInputStatus {
  final String id;
  final String name;
  final bool chosen;

  /// The system lists it now.
  final bool present;
  final bool isVirtual;
  final MidiInputState state;

  /// "open", "not connected", "in use by another program", "off", or the error.
  final String text;

  /// Channel messages in the last second.
  final int activity;

  const MidiInputStatus({
    required this.id,
    required this.name,
    required this.chosen,
    required this.present,
    required this.state,
    required this.text,
    this.isVirtual = false,
    this.activity = 0,
  });

  @override
  String toString() => 'MidiInputStatus($id "$name" ${state.name}: $text, $activity/s)';
}

typedef PeriodicTimerFactory = Timer Function(Duration interval, void Function(Timer) tick);

class MidiInputs {
  final MidiBackend backend;

  /// Called with [toJson] whenever the choice changes (the caller stores it).
  final void Function(Map<String, Object?> prefs)? onPrefs;

  /// How often it refreshes while started.
  final Duration interval;

  /// The timer (tests: a fake; with package:fake_async the default Timer.periodic is fake too).
  final PeriodicTimerFactory periodic;

  final void Function(String line)? log;

  final _chosen = <String>{};
  final _names = <String, String>{}; // last known names of chosen ids (shown while unplugged)
  final _listeners = <void Function()>[];
  final _result = <String, int>{}; // the last open's result per chosen id
  final _samples = <({int t, Map<String, int> msgs})>[];
  final _activity = <String, int>{};
  final recent = <MidiEvent>[];
  static const recentMax = 256;

  Timer? _timer;
  bool _running = false, _available = true;
  List<MidiDevice> _list = const [];
  int _gen = -1;
  String _sig = '';

  MidiInputs(
    this.backend, {
    Iterable<String> chosen = const [],
    Map<String, String> names = const {},
    this.onPrefs,
    this.interval = const Duration(seconds: 1),
    PeriodicTimerFactory? periodic,
    this.log,
  }) : periodic = periodic ?? Timer.periodic {
    _chosen.addAll(chosen);
    _names.addAll(names);
  }

  /// From what [toJson] wrote (also accepts a plain list of ids).
  factory MidiInputs.fromJson(
    MidiBackend backend,
    Object? json, {
    void Function(Map<String, Object?>)? onPrefs,
    Duration interval = const Duration(seconds: 1),
    PeriodicTimerFactory? periodic,
    void Function(String)? log,
  }) {
    final (ids, names) = parseJson(json);
    return MidiInputs(backend, chosen: ids, names: names, onPrefs: onPrefs, interval: interval, periodic: periodic, log: log);
  }

  /// The chosen ids and their names from [toJson]'s map, or a plain list of ids.
  static (Set<String>, Map<String, String>) parseJson(Object? json) {
    final ids = <String>{};
    final names = <String, String>{};
    final list = json is Map ? json['inputs'] : json;
    if (list is List) {
      for (final e in list) {
        if (e is String) {
          ids.add(e);
        } else if (e is Map && e['id'] is String) {
          ids.add(e['id'] as String);
          if (e['name'] is String) names[e['id'] as String] = e['name'] as String;
        }
      }
    }
    return (ids, names);
  }

  /// `{"inputs": [{"id": ..., "name": ...}, ...]}`, sorted by id.
  Map<String, Object?> toJson() => {
    'inputs': [
      for (final id in [..._chosen]..sort()) {'id': id, if (_names[id] != null) 'name': _names[id]},
    ],
  };

  Set<String> get chosen => Set.unmodifiable(_chosen);
  bool get running => _running;

  /// false after start() found no MIDI system.
  bool get available => _available;

  /// Listeners run after every change of the choice, the statuses or the activity.
  void addListener(void Function() f) => _listeners.add(f);
  void removeListener(void Function() f) => _listeners.remove(f);

  void _notify() {
    for (final f in [..._listeners]) {
      f();
    }
  }

  /// Sets up MIDI, opens the chosen inputs that are there, and refreshes every [interval].
  /// false: no MIDI system (nothing runs).
  bool start() {
    if (_running) return true;
    _available = backend.init();
    if (!_available) {
      log?.call('midi: the MIDI system did not start');
      _notify();
      return false;
    }
    _running = true;
    _samples.clear();
    tick();
    _timer = periodic(interval, (_) => tick());
    return true;
  }

  /// Closes every input and stops the timer (nothing runs while stopped).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (!_running) return;
    _running = false;
    backend.closeAll();
    _list = backend.devices();
    _result.clear();
    _samples.clear();
    _activity.clear();
    _sig = '';
    _notify();
  }

  /// stop(), then the backend's shutdown (closes everything, clears the sink).
  void dispose() {
    stop();
    backend.shutdown();
    _listeners.clear();
  }

  /// Chooses or drops an input; while started it opens or closes at once.
  void select(String id, bool on) {
    final changed = on ? _chosen.add(id) : _chosen.remove(id);
    if (!changed) return;
    final d = _find(id);
    if (on && d != null) _names[id] = d.name;
    if (!on) {
      _names.remove(id);
      _result.remove(id);
    }
    onPrefs?.call(toJson());
    if (_running) {
      if (!on && d != null && d.open && !d.isVirtual) {
        backend.close(id);
        log?.call('midi: closed ${d.name}');
      }
      tick();
    } else {
      _notify();
    }
  }

  /// The native sink (striso_virtual's sv_midi_write and its board), by address; 0 detaches
  /// (returns once no call to the previous one runs).
  void setSink(int fnAddress, int userAddress) => backend.setSink(fnAddress, userAddress);

  MidiDevice? _find(String id) {
    for (final d in _list) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// One refresh: notice plugs and unplugs, open what is chosen and there, read the activity.
  /// The timer calls it; tests may too.
  void tick() {
    if (!_running) return;
    _gen = backend.refresh();
    _list = backend.devices();
    var again = false;
    for (final id in _chosen) {
      final d = _find(id);
      if (d == null || !d.present || d.open) continue;
      final r = backend.open(id);
      final before = _result[id];
      _result[id] = r;
      if (r == midiOk) {
        log?.call('midi: opened ${d.name}');
      } else if (before != r) {
        log?.call('midi: ${d.name}: ${midiErrorText(r)}');
      }
      again = true;
    }
    for (final d in _list) {
      if (d.open && !d.isVirtual && !_chosen.contains(d.id)) {
        backend.close(d.id);
        again = true;
      }
      if (_chosen.contains(d.id) && d.present) _names[d.id] = d.name;
    }
    if (again) _list = backend.devices();
    _poll();
    final sig = _signature();
    if (sig != _sig) {
      _sig = sig;
      _notify();
    }
  }

  /// Reads the counters and the monitor (cheap; a UI may call it more often than the tick for a
  /// livelier pip). Returns true when the activity changed.
  bool poll() {
    if (!_running) return false;
    _list = backend.devices();
    final before = _activity.toString();
    _poll();
    final changed = _activity.toString() != before;
    if (changed) {
      _sig = _signature();
      _notify();
    }
    return changed;
  }

  void _poll() {
    final now = backend.clockUs();
    final ev = backend.events();
    recent.addAll(ev);
    if (recent.length > recentMax) recent.removeRange(0, recent.length - recentMax);
    _samples.add((t: now, msgs: {for (final d in _list) d.id: d.messages}));
    // keep one sample at least a second old as the baseline
    while (_samples.length > 2 && now - _samples[1].t >= 1000000) {
      _samples.removeAt(0);
    }
    final base = _samples.first;
    _activity.clear();
    for (final d in _list) {
      final recentMsg = d.lastUs != 0 && now - d.lastUs < 1000000;
      final b = base.msgs[d.id];
      _activity[d.id] = !recentMsg ? 0 : (b == null || identical(base, _samples.last) ? 0 : (d.messages - b) & 0xFFFFFFFF);
    }
  }

  String _signature() => [_gen, for (final s in devices) '${s.id}:${s.state.index}:${s.text}:${s.activity}'].join('|');

  /// Channel messages in the last second from that input (0 when unknown).
  int activityOf(String id) => _activity[id] ?? 0;

  /// Channel messages in the last second, all chosen inputs.
  int get activity {
    var n = 0;
    for (final id in _chosen) {
      n += _activity[id] ?? 0;
    }
    return n;
  }

  /// Per input (the listed ones and the chosen ones that are not there), for the picker.
  List<MidiInputStatus> get devices {
    final out = <MidiInputStatus>[];
    for (final d in _list) {
      out.add(_status(d.id, d));
    }
    for (final id in [..._chosen]..sort()) {
      if (_find(id) == null) out.add(_status(id, null));
    }
    return out;
  }

  /// The status of one id (chosen or listed), or null.
  MidiInputStatus? status(String id) {
    final d = _find(id);
    if (d == null && !_chosen.contains(id)) return null;
    return _status(id, d);
  }

  MidiInputStatus _status(String id, MidiDevice? d) {
    final chosen = _chosen.contains(id);
    final name = d?.name ?? _names[id] ?? id;
    final present = d?.present ?? false;
    MidiInputState st;
    String text;
    final err = _result[id] ?? d?.error ?? midiOk;
    if (!chosen) {
      // a virtual input (inject) is open without being chosen
      (st, text) = d != null && d.open && d.isVirtual ? (MidiInputState.open, 'open') : (MidiInputState.off, 'off');
    } else if (!_running) {
      (st, text) = (MidiInputState.stopped, _available ? 'MIDI is off' : midiErrorText(midiErrSystem));
    } else if (d != null && d.open) {
      (st, text) = (MidiInputState.open, 'open');
    } else if (d == null || !present) {
      (st, text) = (MidiInputState.notConnected, 'not connected');
    } else if (err == midiErrInUse) {
      (st, text) = (MidiInputState.inUse, midiErrorText(midiErrInUse));
    } else if (err != midiOk) {
      (st, text) = (MidiInputState.error, midiErrorText(err));
    } else {
      (st, text) = (MidiInputState.error, 'closed');
    }
    return MidiInputStatus(
      id: id,
      name: name,
      chosen: chosen,
      present: present,
      isVirtual: d?.isVirtual ?? false,
      state: st,
      text: text,
      activity: _activity[id] ?? 0,
    );
  }
}
