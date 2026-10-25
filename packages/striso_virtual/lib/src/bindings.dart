// striso_virtual (the firmware repository's virtual/include/striso_virtual.h) through dart:ffi.
// Every call is short (the library serialises them per board); with real time on, a library
// thread runs the board and the calls only queue bytes and read state.

import 'dart:ffi';
import 'dart:io';

const svApiVersion = 1;

// sv_usb_state
const svUsbDetached = 0, svUsbAttached = 1, svUsbBootloader = 2;
// errors
const svEInval = -1, svENoDev = -2, svEBusy = -3, svELoad = -4, svEState = -5;
// sv_test
const svTestFxInit = 1, svTestMotionOff = 2;
// LEDs
const svLedOff = 0, svLedDim = 1, svLedOn = 2;
const svFlashSize = 0x20000;

final class SvOptions extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> flash;
  @Uint32()
  external int flashLen;
  external Pointer<Char> driveDir;
  @Int32()
  external int portKeyHeld;
  @Uint32()
  external int serial;
  @Int32()
  external int bootMs;
}

final class SvLeds extends Struct {
  @Array(3)
  external Array<Int32> rgb;
  @Array(3)
  external Array<Int32> pwm;
  @Array(4)
  external Array<Int32> updown;
  @Int32()
  external int led1;
}

final class SvState extends Struct {
  @Uint32()
  external int size;
  @Int32()
  external int usb;
  @Int32()
  external int voice;
  @Int32()
  external int voices;
  @Int32()
  external int streaming;
  @Int32()
  external int midiMode;
  @Int32()
  external int resets;
  @Int32()
  external int blocks;
  @Int32()
  external int toBlock;
  @Uint32()
  external int underruns;
  @Float()
  external double volume;
  @Array(10, 5)
  external Array<Array<Float>> controls;
  @Array(8)
  external Array<Float> globals;
}

typedef SvI32VFn = Int32 Function();
typedef SvPVFn = Pointer<Char> Function();
typedef SvCreateFn = Pointer<Void> Function(Pointer<SvOptions>);
typedef SvDestroyFn = Void Function(Pointer<Void>);
typedef SvRenderFn = Int32 Function(Pointer<Void>, Pointer<Float>, Int32);
typedef SvRenderDartFn = int Function(Pointer<Void>, Pointer<Float>, int);
typedef SvTapsFn = Int32 Function(Pointer<Void>, Int32, Pointer<Float>, Pointer<Float>, Pointer<Float>);
typedef SvTapsDartFn = int Function(Pointer<Void>, int, Pointer<Float>, Pointer<Float>, Pointer<Float>);
typedef SvBIFn = Int32 Function(Pointer<Void>, Int32);
typedef SvBIDartFn = int Function(Pointer<Void>, int);
typedef SvBFn = Int32 Function(Pointer<Void>);
typedef SvBDartFn = int Function(Pointer<Void>);
typedef SvBU32Fn = Uint32 Function(Pointer<Void>);
typedef SvBU64Fn = Uint64 Function(Pointer<Void>);
typedef SvBytesFn = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef SvBytesDartFn = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef SvKeyFn = Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32, Int32, Int32);
typedef SvKeyDartFn = int Function(Pointer<Void>, int, int, int, int, int, int);
typedef SvBIIFn = Int32 Function(Pointer<Void>, Int32, Int32);
typedef SvBIIDartFn = int Function(Pointer<Void>, int, int);
typedef SvMotionFn = Int32 Function(Pointer<Void>, Pointer<Int16>);
typedef SvMotionDartFn = int Function(Pointer<Void>, Pointer<Int16>);
typedef SvCtlFn = Int32 Function(Pointer<Void>, Int32, Pointer<Float>);
typedef SvCtlDartFn = int Function(Pointer<Void>, int, Pointer<Float>);
typedef SvLedsFn = Int32 Function(Pointer<Void>, Pointer<SvLeds>);
typedef SvLedsDartFn = int Function(Pointer<Void>, Pointer<SvLeds>);
typedef SvStateFn = Int32 Function(Pointer<Void>, Pointer<SvState>);
typedef SvStateDartFn = int Function(Pointer<Void>, Pointer<SvState>);
typedef SvPathFn = Int32 Function(Pointer<Void>, Pointer<Char>, Int32);
typedef SvPathDartFn = int Function(Pointer<Void>, Pointer<Char>, int);

/// Where striso_virtual may be (the app ships none: it picks a build from its firmware folder, or
/// these): [explicit], $STRISO_VIRTUAL_LIB, a firmware checkout's host build ($STRISO_FW_DIR or ../striso-control-firmware from the current directory
/// and its parents: build/host-virtual/virtual or build/host/virtual).
List<String> strisoVirtualCandidates({String? explicit}) {
  final name = Platform.isWindows ? 'striso_virtual.dll' : (Platform.isMacOS ? 'libstriso_virtual.dylib' : 'libstriso_virtual.so');
  final out = <String>[];
  if (explicit != null) out.add(explicit);
  final env = Platform.environment['STRISO_VIRTUAL_LIB'];
  if (env != null && env.isNotEmpty) out.add(env);
  final fws = <String>[];
  final fwEnv = Platform.environment['STRISO_FW_DIR'];
  if (fwEnv != null && fwEnv.isNotEmpty) fws.add(fwEnv);
  for (var d = Directory.current.absolute; ; d = d.parent) {
    fws.add('${d.path}/../striso-control-firmware');
    if (d.parent.path == d.path) break;
  }
  for (final fw in fws) {
    for (final preset in ['host-virtual', 'host']) {
      out.add('$fw/build/$preset/virtual/$name');
    }
  }
  return out;
}

class StrisoVirtualLib {
  final DynamicLibrary _l;
  final String path;

  late final int Function() apiVersion = _l.lookupFunction<SvI32VFn, int Function()>('sv_api_version');
  late final Pointer<Char> Function() _firmwareVersion = _l.lookupFunction<SvPVFn, Pointer<Char> Function()>('sv_firmware_version');
  late final Pointer<Char> Function() lastError = _l.lookupFunction<SvPVFn, Pointer<Char> Function()>('sv_last_error');
  late final Pointer<Void> Function(Pointer<SvOptions>) create = _l.lookupFunction<SvCreateFn, Pointer<Void> Function(Pointer<SvOptions>)>(
    'sv_create',
  );
  late final void Function(Pointer<Void>) destroy = _l.lookupFunction<SvDestroyFn, void Function(Pointer<Void>)>('sv_destroy');
  late final SvRenderDartFn render = _l.lookupFunction<SvRenderFn, SvRenderDartFn>('sv_render');
  late final SvTapsDartFn renderTaps = _l.lookupFunction<SvTapsFn, SvTapsDartFn>('sv_render_taps');
  late final SvBIDartFn advanceMs = _l.lookupFunction<SvBIFn, SvBIDartFn>('sv_advance_ms');
  late final int Function(Pointer<Void>) timeFrames = _l.lookupFunction<SvBU64Fn, int Function(Pointer<Void>)>('sv_time_frames');
  late final SvBIDartFn realtimeStart = _l.lookupFunction<SvBIFn, SvBIDartFn>('sv_realtime_start');
  late final SvBDartFn realtimeStop = _l.lookupFunction<SvBFn, SvBDartFn>('sv_realtime_stop');
  late final SvRenderDartFn readAudio = _l.lookupFunction<SvRenderFn, SvRenderDartFn>('sv_read_audio');
  late final SvBDartFn usbState = _l.lookupFunction<SvBFn, SvBDartFn>('sv_usb_state');
  late final int Function(Pointer<Void>) usbGeneration = _l.lookupFunction<SvBU32Fn, int Function(Pointer<Void>)>('sv_usb_generation');
  late final SvBytesDartFn consoleWrite = _l.lookupFunction<SvBytesFn, SvBytesDartFn>('sv_console_write');
  late final SvBytesDartFn consoleRead = _l.lookupFunction<SvBytesFn, SvBytesDartFn>('sv_console_read');
  late final SvBytesDartFn midiWrite = _l.lookupFunction<SvBytesFn, SvBytesDartFn>('sv_midi_write');
  late final SvBytesDartFn midiRead = _l.lookupFunction<SvBytesFn, SvBytesDartFn>('sv_midi_read');
  late final SvKeyDartFn injectKey = _l.lookupFunction<SvKeyFn, SvKeyDartFn>('sv_inject_key');
  late final SvBIIDartFn injectControl = _l.lookupFunction<SvBIIFn, SvBIIDartFn>('sv_inject_control');
  late final SvMotionDartFn injectMotion = _l.lookupFunction<SvMotionFn, SvMotionDartFn>('sv_inject_motion');
  late final SvCtlDartFn setEngineControls = _l.lookupFunction<SvCtlFn, SvCtlDartFn>('sv_set_engine_controls');
  late final SvBIDartFn selectVoice = _l.lookupFunction<SvBIFn, SvBIDartFn>('sv_select_voice');
  late final SvLedsDartFn getLeds = _l.lookupFunction<SvLedsFn, SvLedsDartFn>('sv_get_leds');
  late final SvStateDartFn getState = _l.lookupFunction<SvStateFn, SvStateDartFn>('sv_get_state');
  late final SvBytesDartFn getFlash = _l.lookupFunction<SvBytesFn, SvBytesDartFn>('sv_get_flash');
  late final SvPathDartFn drivePath = _l.lookupFunction<SvPathFn, SvPathDartFn>('sv_drive_path');
  late final SvBIIDartFn test = _l.lookupFunction<SvBIIFn, SvBIIDartFn>('sv_test');

  StrisoVirtualLib._(this._l, this.path);

  String get firmwareVersion => _cstr(_firmwareVersion());

  static String? loadError;
  static StrisoVirtualLib? _cached;
  static final _byPath = <String, StrisoVirtualLib>{};

  /// The address of sv_audio_source: an audio callback for striso_audio's sa_set_source.
  Pointer<Void> get audioSource => _l.lookup<Void>('sv_audio_source');

  /// The address of sv_midi_write (the board's USB-MIDI input): a sink for striso_audio's MIDI
  /// inputs (sa_midi_set_sink), the board as its user pointer.
  Pointer<Void> get midiSink => _l.lookup<Void>('sv_midi_write');

  /// The library, or throws (the candidates tried in the message). With [explicit], that file
  /// only (a candidate firmware build's striso_virtual); else the first one found, once per isolate.
  static StrisoVirtualLib load({String? explicit}) {
    if (explicit != null) {
      final abs = File(explicit).absolute.path;
      final have = _byPath[abs];
      if (have != null) return have;
      if (!File(abs).existsSync()) throw StateError(loadError = 'striso_virtual not found: $abs');
      final DynamicLibrary dl;
      try {
        dl = DynamicLibrary.open(abs);
      } catch (e) {
        throw StateError(loadError = missingRuntime() ?? '$abs could not be loaded: $e');
      }
      final int api;
      try {
        api = dl.lookupFunction<SvI32VFn, int Function()>('sv_api_version')();
      } catch (_) {
        dl.close();
        throw StateError(loadError = '$abs is not a striso_virtual library (no sv_api_version)');
      }
      final why = apiMismatch(api);
      if (why != null) {
        dl.close();
        throw StateError(loadError = '$abs: $why');
      }
      return _byPath[abs] = StrisoVirtualLib._(dl, abs);
    }
    if (_cached != null) return _cached!;
    final tried = <String>[];
    for (final p in strisoVirtualCandidates(explicit: explicit)) {
      if (!File(p).existsSync()) {
        tried.add('$p (missing)');
        continue;
      }
      try {
        final l = StrisoVirtualLib._(DynamicLibrary.open(p), File(p).absolute.path);
        if (l.apiVersion() != svApiVersion) {
          tried.add('$p (API ${l.apiVersion()}, need $svApiVersion)');
          continue;
        }
        return _cached = l;
      } catch (e) {
        tried.add('$p ($e)');
      }
    }
    loadError = 'striso_virtual not found: ${tried.join('; ')}';
    throw StateError(loadError!);
  }

  /// The Windows build of striso_virtual links the Microsoft C++ runtime, MSVCP140_ATOMIC_WAIT.dll
  /// among it (Visual C++ 2015-2022, 14.28 or later). When one of them is not on this computer the
  /// load fails with a bare "error 126": this says what to install. Null when they are all there
  /// (or not on Windows). [open] is for tests.
  static String? missingRuntime({bool? windows, void Function(String)? open}) {
    if (!(windows ?? Platform.isWindows)) return null;
    final o = open ?? (String n) => DynamicLibrary.open(n);
    final missing = <String>[];
    for (final n in const ['VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'MSVCP140.dll', 'MSVCP140_ATOMIC_WAIT.dll']) {
      try {
        o(n);
      } catch (_) {
        missing.add(n);
      }
    }
    if (missing.isEmpty) return null;
    return 'the virtual Striso needs the Microsoft Visual C++ Redistributable 2015-2022 (x64), 14.28 or later '
        '(${missing.join(', ')} ${missing.length == 1 ? 'is' : 'are'} missing): install it from https://aka.ms/vs/17/release/vc_redist.x64.exe';
  }

  /// Why a library with C API [api] is refused (null: it fits). Not compatibility: a guard.
  static String? apiMismatch(int api) =>
      api == svApiVersion ? null : 'its C API is version $api, this app speaks version $svApiVersion: use a firmware build for this app';

  /// Lets go of the library at [path] (every board on it must be disposed first): the next load
  /// of that path is a fresh instance.
  static void unload(String path) {
    final abs = File(path).absolute.path;
    final l = _byPath.remove(abs) ?? (_cached?.path == abs ? _cached : null);
    if (_cached?.path == abs) _cached = null;
    l?._l.close();
  }

  /// The library at [path] is loaded.
  static bool isLoaded(String path) => _byPath.containsKey(File(path).absolute.path) || _cached?.path == File(path).absolute.path;

  static StrisoVirtualLib? tryLoad({String? explicit}) {
    try {
      return load(explicit: explicit);
    } catch (_) {
      return null;
    }
  }
}

String _cstr(Pointer<Char> p) {
  if (p == nullptr) return '';
  final bytes = <int>[];
  final u = p.cast<Uint8>();
  for (var i = 0; u[i] != 0; i++) {
    bytes.add(u[i]);
  }
  return String.fromCharCodes(bytes);
}

String cString(Pointer<Char> p) => _cstr(p);
