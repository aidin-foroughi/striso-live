// MIDI input for Virtual (striso_midi.h in the native library): the devices, the backend
// interface the app's selection logic (MidiInputs) runs on, and a scriptable fake for tests.
//
// The MIDI itself never passes through Dart: the native library hands the open inputs' messages,
// on the MIDI driver's thread, to one sink (striso_virtual's sv_midi_write). Dart only picks the
// inputs, attaches the sink by its address and reads counters and the monitor.

/// striso_midi.h's error codes.
const midiOk = 0;
const midiErrNotFound = -2;
const midiErrBadArg = -10;
const midiErrNotInitialised = -11;
const midiErrInUse = -20;
const midiErrOpen = -21;
const midiErrGone = -22;
const midiErrSystem = -23;
const midiErrFull = -24;

/// A short text for a striso_midi error code.
String midiErrorText(int code) => switch (code) {
  midiOk => 'ok',
  midiErrNotFound => 'not connected',
  midiErrBadArg => 'bad argument',
  midiErrNotInitialised => 'MIDI is not started',
  midiErrInUse => 'in use by another program',
  midiErrOpen => 'the system would not open it',
  midiErrGone => 'disconnected',
  midiErrSystem => 'the MIDI system did not start',
  midiErrFull => 'too many MIDI devices',
  _ => 'error $code',
};

/// One input of the list (sa_midi_device).
class MidiDevice {
  final String name;

  /// Stable id: macOS the source's unique id, Windows the name (plus `#2`, `#3` for duplicates).
  final String id;
  final bool open;

  /// [midiOk] or what happened last ([midiErrInUse], [midiErrOpen], [midiErrGone]).
  final int error;

  /// Channel messages it produced so far (wraps at 2^32).
  final int messages;

  /// `sa_clock_us` of its last message, 0 none.
  final int lastUs;

  /// Stable number while the library is initialised: [MidiEvent.device].
  final int slot;

  /// The system lists it now (a gone input that was open stays listed with false).
  final bool present;

  /// Made by `inject`, no system port.
  final bool isVirtual;

  /// The system's code of the last failure (MMRESULT, OSStatus).
  final int osError;

  /// 1: MIDI 1.0 (bytes, to the sink); 2: MIDI 2.0 (Universal MIDI Packets, to the UMP sink).
  final int protocol;
  bool get midi2 => protocol == 2;

  const MidiDevice({
    required this.name,
    required this.id,
    this.open = false,
    this.error = midiOk,
    this.messages = 0,
    this.lastUs = 0,
    this.slot = 0,
    this.present = true,
    this.isVirtual = false,
    this.osError = 0,
    this.protocol = 1,
  });

  @override
  String toString() =>
      'MidiDevice($id "$name"${midi2 ? ' MIDI 2.0' : ''}${open ? ' open' : ''}${present ? '' : ' gone'}${isVirtual ? ' virtual' : ''}, error $error, $messages msgs)';
}

/// One channel message the sink got (sa_midi_event).
class MidiEvent {
  final int tUs;

  /// The device's [MidiDevice.slot].
  final int device;

  /// 2 or 3 bytes: status, data.
  final List<int> bytes;
  const MidiEvent(this.tUs, this.device, this.bytes);

  @override
  String toString() => 'MidiEvent($tUs, slot $device, ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})';
}

/// The words of the UMP packet that starts with word [w] (by its message type).
int umpWords(int w) => const [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][(w >> 28) & 0xF];

/// What MidiInputs needs of the native MIDI input (NativeMidiBackend) or of a fake.
abstract class MidiBackend {
  /// Sets up the system's MIDI (idempotent). false: not available.
  bool init();

  /// Closes everything, clears the sink, forgets the devices.
  void shutdown();

  /// Re-enumerates now; returns the list generation (bumps when the list changed).
  int refresh();

  /// The list of the last refresh.
  List<MidiDevice> devices();

  /// Opens and starts that input: [midiOk] or an error code.
  int open(String id);
  void close(String id);
  void closeAll();

  /// The sink by address: a C function `int32_t (*)(void* user, const uint8_t* packets, int32_t n)`
  /// (striso_virtual's sv_midi_write) and its user (the sv_board*). 0: none. Returns only when no
  /// call to the previous sink is still running.
  void setSink(int fnAddress, int userAddress);

  /// Raw MIDI bytes through the parser, sink and monitor as the device with that id (an unknown id:
  /// a virtual device). Returns the channel messages produced, or an error code.
  int inject(String id, List<int> bytes);

  /// Takes the monitor's events (oldest first).
  List<MidiEvent> events();

  /// The library's clock (`sa_clock_us`): [MidiDevice.lastUs] and [MidiEvent.tUs] are on it.
  int clockUs();

  /// The UMP sink (sa_midi_set_ump_sink: striso_virtual's sv_ump_write and its board), by address,
  /// for MIDI 2.0 inputs; 0 detaches.
  void setUmpSink(int fnAddress, int userAddress);

  /// UMP words, untouched, as the MIDI 2.0 input [id] (a test device when it is no system input).
  int injectUmp(String id, List<int> words);

  /// Why there is no MIDI 2.0 here ('' when there is, or nothing to say).
  String midi2Status();
}

/// The native parser's rules in Dart (striso_midi.c, sa_midi_parse), for the fake: one USB-MIDI
/// packet (cable 0) per channel message; running status; real-time, system common and SysEx
/// dropped; a note-on with velocity 0 kept.
class MidiParser {
  int _status = 0, _have = 0, _need = 0, _skip = 0;
  bool _sysex = false;
  final _data = [0, 0];

  void reset() {
    _status = _have = _need = _skip = 0;
    _sysex = false;
  }

  /// The packets (4 bytes each) of the complete messages in [bytes].
  List<int> feed(List<int> bytes) {
    final out = <int>[];
    for (final raw in bytes) {
      final b = raw & 0xFF;
      if (b >= 0xF8) continue;
      if (b & 0x80 != 0) {
        _have = 0;
        _skip = 0;
        _sysex = false;
        if (b < 0xF0) {
          _status = b;
          _need = (b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0 ? 1 : 2;
        } else {
          _status = 0;
          if (b == 0xF0) {
            _sysex = true;
          } else if (b == 0xF1 || b == 0xF3) {
            _skip = 1;
          } else if (b == 0xF2) {
            _skip = 2;
          }
        }
        continue;
      }
      if (_sysex) continue;
      if (_skip > 0) {
        _skip--;
        continue;
      }
      if (_status == 0) continue;
      _data[_have++] = b;
      if (_have < _need) continue;
      out.addAll([_status >> 4, _status, _data[0], _need == 2 ? _data[1] : 0]);
      _have = 0;
    }
    return out;
  }
}

class _FakeDev {
  final String id;
  String name;
  bool present = true, open = false, isVirtual = false, gone = false, midi2 = false;
  int error = midiOk, messages = 0, lastUs = 0;
  final int slot;
  final parser = MidiParser();
  _FakeDev(this.id, this.name, this.slot);

  MidiDevice get view => MidiDevice(
    name: name,
    id: id,
    open: open,
    error: error,
    messages: messages,
    lastUs: lastUs,
    slot: slot,
    present: present,
    isVirtual: isVirtual,
    protocol: midi2 ? 2 : 1,
  );
}

/// A scriptable MidiBackend: devices are plugged and unplugged by the test, an open can fail
/// ("in use" or any code), and what would reach the native sink is parsed by [MidiParser] and
/// handed to [onSink] (when a sink address is set), so a test sees the exact packets. Like the
/// native library, refresh is what notices a plug or an unplug.
class FakeMidiBackend implements MidiBackend {
  /// false: init fails (no MIDI system).
  bool available;
  bool inited = false;

  /// The clock in microseconds ([clockUs]); tests move it, or set [clock] (e.g. fake_async's).
  int nowUs = 1000000;
  int Function()? clock;

  /// How many refreshes were asked (a stopped MidiInputs asks none).
  int refreshes = 0;

  /// Ids whose open fails with [midiErrInUse]; [openErrors] any other code.
  final inUse = <String>{};
  final openErrors = <String, int>{};

  /// What the sink got, one entry per call (the packets, 4 bytes each).
  final sinkCalls = <List<int>>[];

  /// What the UMP sink got (the words of each delivery), and a callback for each.
  final umpCalls = <List<int>>[];
  void Function(List<int> words)? onUmpSink;
  int umpSinkFn = 0, umpSinkUser = 0;

  /// MIDI 2.0 (UMP) inputs among the plugged ones (by id).
  final midi2 = <String>{};
  String midi2Why = '';
  void Function(List<int> packets)? onSink;
  int sinkFn = 0, sinkUser = 0;

  /// Every open and close asked, in order ("open id", "close id").
  final calls = <String>[];

  final _system = <String, String>{}; // what is plugged now: id -> name (in plug order)
  final _devs = <String, _FakeDev>{};
  final _order = <String>[];
  final _events = <MidiEvent>[];
  int _gen = 0, _slots = 0;
  static const ringSize = 4096;
  int eventsLost = 0;

  FakeMidiBackend({this.available = true});

  /// A device appears (seen at the next refresh).
  void plug(String id, {String? name}) => _system[id] = name ?? id;

  /// It disappears (an open one is closed with [midiErrGone] at the next refresh).
  void unplug(String id) => _system.remove(id);

  /// The driver delivers [bytes] from that device: through the parser to the sink, when it is open.
  int play(String id, List<int> bytes) {
    final d = _devs[id];
    if (d == null || !d.open) return 0;
    return _deliver(d, bytes);
  }

  int _deliver(_FakeDev d, List<int> bytes) {
    final pk = d.parser.feed(bytes);
    final n = pk.length ~/ 4;
    if (n == 0) return 0;
    for (var i = 0; i < n; i++) {
      if (_events.length >= ringSize) {
        eventsLost++;
        continue;
      }
      final cin = pk[4 * i];
      _events.add(MidiEvent(clockUs(), d.slot, pk.sublist(4 * i + 1, 4 * i + (cin == 0xC || cin == 0xD ? 3 : 4))));
    }
    d.messages += n;
    d.lastUs = clockUs();
    if (sinkFn != 0) {
      sinkCalls.add(pk);
      onSink?.call(pk);
    }
    return n;
  }

  _FakeDev _dev(String id, String name) => _devs.putIfAbsent(id, () => _FakeDev(id, name, _slots++));

  @override
  bool init() {
    if (!available) return false;
    if (!inited) {
      inited = true;
      refresh();
    }
    return true;
  }

  @override
  void shutdown() {
    _devs.clear();
    _order.clear();
    _events.clear();
    sinkFn = sinkUser = 0;
    inited = false;
    _gen++;
  }

  @override
  int refresh() {
    refreshes++;
    final before = [for (final id in _order) '$id/${_devs[id]!.present}/${_devs[id]!.name}'];
    if (inited) {
      for (final d in _devs.values) {
        if (!d.isVirtual) d.present = false;
      }
      for (final e in _system.entries) {
        final d = _dev(e.key, e.value);
        if (d.isVirtual) continue;
        d.name = e.value;
        d.present = true;
      }
      for (final d in _devs.values) {
        if (!d.isVirtual && !d.present && d.open) {
          d.open = false;
          d.error = midiErrGone;
          d.gone = true;
        }
      }
    }
    _order
      ..clear()
      ..addAll([
        for (final id in _system.keys)
          if (_devs[id] != null && !_devs[id]!.isVirtual && _devs[id]!.present) id,
        for (final d in _devs.values)
          if (!d.isVirtual && !d.present && d.gone) d.id,
        for (final d in _devs.values)
          if (d.isVirtual) d.id,
      ]);
    final after = [for (final id in _order) '$id/${_devs[id]!.present}/${_devs[id]!.name}'];
    if (before.join('|') != after.join('|')) _gen++;
    return _gen;
  }

  @override
  List<MidiDevice> devices() => [
    for (final id in _order) (_devs[id]!..midi2 = midi2.contains(id)).view,
  ];

  @override
  int open(String id) {
    calls.add('open $id');
    final v = _devs[id];
    if (v != null && v.isVirtual) return midiOk;
    if (!inited) return midiErrNotInitialised;
    refresh();
    final d = _devs[id];
    if (d == null || !d.present) return midiErrNotFound;
    if (d.open) return midiOk;
    final err = inUse.contains(id) ? midiErrInUse : (openErrors[id] ?? midiOk);
    if (err != midiOk) {
      d.error = err;
      return err;
    }
    d.parser.reset();
    d.open = true;
    d.error = midiOk;
    d.gone = false;
    return midiOk;
  }

  @override
  void close(String id) {
    calls.add('close $id');
    final d = _devs[id];
    if (d == null || !_order.contains(id)) return;
    if (d.isVirtual || !d.present) {
      _devs.remove(id);
      refresh();
    } else {
      d.open = false;
      d.error = midiOk;
      d.gone = false;
    }
  }

  @override
  void closeAll() {
    calls.add('closeAll');
    for (final d in [..._devs.values]) {
      if (d.isVirtual || (!d.present && d.gone)) {
        _devs.remove(d.id);
      } else {
        d.open = false;
        d.error = midiOk;
        d.gone = false;
      }
    }
    refresh();
  }

  @override
  void setUmpSink(int fnAddress, int userAddress) {
    umpSinkFn = fnAddress;
    umpSinkUser = userAddress;
  }

  @override
  int injectUmp(String id, List<int> words) {
    midi2.add(id);
    var packets = 0;
    for (var i = 0; i < words.length; i += umpWords(words[i])) {
      packets++;
    }
    umpCalls.add(List.of(words));
    onUmpSink?.call(List.of(words));
    return packets;
  }

  @override
  String midi2Status() => midi2Why;

  @override
  void setSink(int fnAddress, int userAddress) {
    sinkFn = fnAddress;
    sinkUser = fnAddress == 0 ? 0 : userAddress;
  }

  @override
  int inject(String id, List<int> bytes) {
    var d = _devs[id];
    if (d == null) {
      d = _dev(id, id)
        ..isVirtual = true
        ..open = true;
      refresh();
    }
    if (!d.open) return 0;
    return _deliver(d, bytes);
  }

  @override
  List<MidiEvent> events() {
    final out = [..._events];
    _events.clear();
    return out;
  }

  @override
  int clockUs() => clock?.call() ?? nowUs;
}
