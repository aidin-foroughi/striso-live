// dart:ffi binding of striso_midi.h (the MIDI input in the striso_audio library). Uses the
// library StrisoAudioLib already loaded; a build without MIDI (no sa_midi_init) gives null.
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'midi.dart';
import 'native.dart' show StrisoAudioLib;

/// striso_midi.h's SA_MIDI_API_VERSION this binding is written for.
const midiApiVersion = 1;

/// sa_midi_device (552 bytes).
final class SaMidiDevice extends Struct {
  @Array(256)
  external Array<Uint8> name;
  @Array(256)
  external Array<Uint8> id;
  @Int32()
  external int open;
  @Int32()
  external int error;
  @Uint32()
  external int messages;
  @Int32()
  external int slot;
  @Int64()
  external int last_us;
  @Int32()
  external int present;
  @Int32()
  external int is_virtual;
  @Int32()
  external int os_error;
  @Int32()
  external int reserved;
}

/// sa_midi_event (16 bytes).
final class SaMidiEvent extends Struct {
  @Int64()
  external int t_us;
  @Int32()
  external int device;
  @Uint8()
  external int len;
  @Array(3)
  external Array<Uint8> bytes;
}

typedef _SinkN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);

String _cstr(Array<Uint8> a, int max) {
  final b = <int>[];
  for (var i = 0; i < max && a[i] != 0; i++) {
    b.add(a[i]);
  }
  return const Utf8Decoder(allowMalformed: true).convert(b);
}

/// The native MIDI input. All calls are quick (no device I/O but open/close and the enumeration).
class NativeMidiBackend implements MidiBackend {
  final DynamicLibrary lib;
  NativeMidiBackend(this.lib);

  /// The MIDI input of an already loaded striso_audio, or null when that build has none (no
  /// sa_midi_init) or its structs differ from this binding's.
  static NativeMidiBackend? of(StrisoAudioLib l) => ofLibrary(l.lib);

  static NativeMidiBackend? ofLibrary(DynamicLibrary lib) {
    if (!lib.providesSymbol('sa_midi_init')) return null;
    try {
      final b = NativeMidiBackend(lib);
      if (b._apiVersion() != midiApiVersion || b._sizeofDevice() != sizeOf<SaMidiDevice>() || b._sizeofEvent() != sizeOf<SaMidiEvent>()) return null;
      return b;
    } catch (_) {
      return null;
    }
  }

  late final _apiVersion = lib.lookupFunction<Int32 Function(), int Function()>('sa_midi_api_version');
  late final _sizeofDevice = lib.lookupFunction<Int32 Function(), int Function()>('sa_midi_sizeof_device');
  late final _sizeofEvent = lib.lookupFunction<Int32 Function(), int Function()>('sa_midi_sizeof_event');
  late final _init = lib.lookupFunction<Int32 Function(), int Function()>('sa_midi_init');
  late final _shutdown = lib.lookupFunction<Void Function(), void Function()>('sa_midi_shutdown');
  late final _refresh = lib.lookupFunction<Uint32 Function(), int Function()>('sa_midi_refresh');
  late final _count = lib.lookupFunction<Int32 Function(), int Function()>('sa_midi_count');
  late final _get = lib.lookupFunction<Int32 Function(Int32, Pointer<SaMidiDevice>), int Function(int, Pointer<SaMidiDevice>)>('sa_midi_get');
  late final _open = lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('sa_midi_open');
  late final _close = lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('sa_midi_close');
  late final _closeAll = lib.lookupFunction<Void Function(), void Function()>('sa_midi_close_all');
  late final _setSink = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>), void Function(Pointer<Void>, Pointer<Void>)>(
    'sa_midi_set_sink',
  );
  late final _inject = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Uint8>, Int32), int Function(Pointer<Utf8>, Pointer<Uint8>, int)>(
    'sa_midi_inject',
  );
  late final _events = lib.lookupFunction<Int32 Function(Pointer<SaMidiEvent>, Int32), int Function(Pointer<SaMidiEvent>, int)>('sa_midi_events');
  late final _eventsLost = lib.lookupFunction<Uint32 Function(), int Function()>('sa_midi_events_lost');
  late final _clock = lib.lookupFunction<Int64 Function(), int Function()>('sa_clock_us');
  late final _testRead = lib.lookupFunction<Int32 Function(Pointer<Uint8>, Int32), int Function(Pointer<Uint8>, int)>('sa_midi_test_sink_read');

  // one buffer each, for the life of the binding (the calls are synchronous)
  static const _evMax = 512;
  late final Pointer<SaMidiDevice> _dev = calloc<SaMidiDevice>();
  late final Pointer<SaMidiEvent> _ev = calloc<SaMidiEvent>(_evMax);

  T _withStr<T>(String s, T Function(Pointer<Utf8>) f) {
    final p = s.toNativeUtf8();
    try {
      return f(p);
    } finally {
      calloc.free(p);
    }
  }

  @override
  bool init() => _init() == midiOk;

  @override
  void shutdown() => _shutdown();

  @override
  int refresh() => _refresh();

  @override
  List<MidiDevice> devices() {
    final n = _count();
    final out = <MidiDevice>[];
    for (var i = 0; i < n; i++) {
      if (_get(i, _dev) != midiOk) continue;
      final d = _dev.ref;
      out.add(
        MidiDevice(
          name: _cstr(d.name, 256),
          id: _cstr(d.id, 256),
          open: d.open != 0,
          error: d.error,
          messages: d.messages,
          lastUs: d.last_us,
          slot: d.slot,
          present: d.present != 0,
          isVirtual: d.is_virtual != 0,
          osError: d.os_error,
        ),
      );
    }
    return out;
  }

  @override
  int open(String id) => _withStr(id, _open);

  @override
  void close(String id) => _withStr(id, _close);

  @override
  void closeAll() => _closeAll();

  @override
  void setSink(int fnAddress, int userAddress) => _setSink(Pointer<Void>.fromAddress(fnAddress), Pointer<Void>.fromAddress(userAddress));

  @override
  int inject(String id, List<int> bytes) {
    final b = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      for (var i = 0; i < bytes.length; i++) {
        b[i] = bytes[i];
      }
      return _withStr(id, (p) => _inject(p, b, bytes.length));
    } finally {
      calloc.free(b);
    }
  }

  @override
  List<MidiEvent> events() {
    final out = <MidiEvent>[];
    while (true) {
      final n = _events(_ev, _evMax);
      for (var i = 0; i < n; i++) {
        final e = (_ev + i).ref;
        out.add(MidiEvent(e.t_us, e.device, [for (var j = 0; j < e.len && j < 3; j++) e.bytes[j]]));
      }
      if (n < _evMax) break;
    }
    return out;
  }

  /// Monitor events dropped because the ring was full (since sa_midi_init).
  int get eventsLost => _eventsLost();

  @override
  int clockUs() => _clock();

  /// The address of sa_midi_test_sink: a sink that records what it gets (tests).
  int get testSinkAddress => lib.lookup<NativeFunction<_SinkN>>('sa_midi_test_sink').address;

  /// Takes what sa_midi_test_sink recorded (the packets, 4 bytes each).
  List<int> testSinkRead() {
    const max = 65536;
    final b = calloc<Uint8>(max);
    try {
      final n = _testRead(b, max);
      return [for (var i = 0; i < n; i++) b[i]];
    } finally {
      calloc.free(b);
    }
  }
}
