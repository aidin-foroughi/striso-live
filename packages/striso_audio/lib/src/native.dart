// striso_audio (packages/striso_audio/native) through dart:ffi. Thin: every function returns at
// once (the library's own control thread opens the devices), so the calls run on the caller's
// isolate. Names follow striso_audio.h.

import 'dart:convert' show Utf8Decoder;
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'backend.dart';

const _apiVersion = 2;

final class SaDevice extends Struct {
  @Array(256)
  external Array<Uint8> name;
  @Array(256)
  external Array<Uint8> id;
  @Int32()
  external int is_default;
  @Int32()
  external int is_striso;
  @Int32()
  external int native_bits;
  @Int32()
  external int native_rate;
  @Int32()
  external int native_channels;
  @Int32()
  external int transport;
  @Int32()
  external int dev_min;
  @Int32()
  external int dev_default;
}

final class SaEvent extends Struct {
  @Uint32()
  external int seq;
  @Int32()
  external int type;
  @Uint32()
  external int t_lo;
  @Uint32()
  external int t_hi;
  @Int32()
  external int a;
  @Int32()
  external int b;
  @Int32()
  external int c;
  @Int32()
  external int reserved;
}

final class SaStatus extends Struct {
  @Int32()
  external int api_version;
  @Int32()
  external int initialised;
  @Int32()
  external int backend;
  @Uint32()
  external int config_gen;
  @Uint32()
  external int devices_gen;

  @Int32()
  external int capture_state;
  @Int32()
  external int capture_error;
  @Int32()
  external int capture_result;
  @Int32()
  external int capture_rate;
  @Int32()
  external int capture_channels;
  @Int32()
  external int capture_period;
  @Int32()
  external int capture_exclusive;
  @Int32()
  external int capture_bits;
  @Uint32()
  external int capture_callbacks;

  @Int32()
  external int playback_state;
  @Int32()
  external int playback_error;
  @Int32()
  external int playback_result;
  @Int32()
  external int playback_rate;
  @Int32()
  external int playback_period;
  @Int32()
  external int playback_periods;
  @Uint32()
  external int playback_callbacks;

  @Float()
  external double level_l;
  @Float()
  external double level_r;
  @Float()
  external double level_out;
  @Float()
  external double gain;

  @Float()
  external double latency_ms;
  @Float()
  external double ring_ms;
  @Float()
  external double target_ms;
  @Float()
  external double drift_ppm;
  @Uint32()
  external int underruns;
  @Uint32()
  external int overruns;
  @Uint32()
  external int resyncs;
  @Int32()
  external int streaming;

  @Int32()
  external int record_state;
  @Int32()
  external int record_error;
  @Int32()
  external int record_bits;
  @Uint32()
  external int record_frames;
  @Uint32()
  external int record_dropped;

  @Int32()
  external int mic_permission;
  @Int32()
  external int playback_exclusive;
  @Array(3)
  external Array<Uint32> reserved;

  // API 2
  @Int32()
  external int capture_buffer;
  @Int32()
  external int capture_dev_min;
  @Int32()
  external int capture_dev_default;
  @Int32()
  external int capture_stream_latency;
  @Int32()
  external int capture_excl_result;
  @Int32()
  external int playback_buffer;
  @Int32()
  external int playback_dev_min;
  @Int32()
  external int playback_dev_default;
  @Int32()
  external int playback_stream_latency;
  @Int32()
  external int playback_excl_result;
  @Int32()
  external int playback_transport;
  @Float()
  external double in_ms;
  @Float()
  external double out_ms;
  @Float()
  external double margin_ms;
  @Uint32()
  external int in_late;
  @Uint32()
  external int out_late;
  @Uint32()
  external int out_glitches;
  @Uint32()
  external int servo_limits;
  @Uint32()
  external int retargets;
  @Uint32()
  external int events_lost;
  @Uint32()
  external int cap_nominal_us;
  @Uint32()
  external int cap_max_gap_us;
  @Uint32()
  external int cap_recent_gap_us;
  @Uint32()
  external int cap_burst;
  @Uint32()
  external int cap_burst_max;
  @Uint32()
  external int play_nominal_us;
  @Uint32()
  external int play_max_gap_us;
  @Uint32()
  external int play_recent_gap_us;
  @Uint32()
  external int play_burst;
  @Uint32()
  external int play_burst_max;
  @Uint32()
  external int now_lo;
  @Uint32()
  external int now_hi;
  @Uint32()
  external int event_seq;
  @Int32()
  external int rt_capture;
  @Int32()
  external int rt_playback;
  @Int32()
  external int rt_control;
  @Int32()
  external int timer_1ms;
  @Int32()
  external int power_throttling_off;
  @Array(4)
  external Array<Uint32> reserved2;
}

/// Where to look for the library: STRISO_AUDIO_LIB, next to the executable (Windows), the app
/// bundle's Frameworks (macOS), a development build in the package.
List<String> strisoAudioCandidates({String? explicit}) {
  final out = <String>[];
  if (explicit != null) out.add(explicit);
  final env = Platform.environment['STRISO_AUDIO_LIB'];
  if (env != null && env.isNotEmpty) out.add(env);
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    out.addAll(['$exeDir${sep}striso_audio.dll', 'striso_audio.dll']);
  } else if (Platform.isMacOS) {
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    out.addAll([
      '$contents/Frameworks/libstriso_audio.dylib',
      '$exeDir/libstriso_audio.dylib',
      'packages/striso_audio/native/build/macos/libstriso_audio.dylib',
    ]);
  } else {
    out.addAll(['$exeDir/lib/libstriso_audio.so', 'libstriso_audio.so']);
  }
  return out;
}

String _str(Array<Uint8> a, int max) {
  final bytes = <int>[];
  for (var i = 0; i < max && a[i] != 0; i++) {
    bytes.add(a[i]);
  }
  return const Utf8Decoder(allowMalformed: true).convert(bytes);
}

class StrisoAudioLib {
  final DynamicLibrary lib;
  final String path;
  StrisoAudioLib._(this.lib, this.path);

  /// Opens the first library that loads and matches this binding; throws with what was tried.
  factory StrisoAudioLib.load({String? explicit}) {
    final tried = <String>[];
    for (final p in strisoAudioCandidates(explicit: explicit)) {
      if (p.contains(Platform.pathSeparator) || p.contains('/')) {
        if (!File(p).existsSync()) {
          tried.add('$p (missing)');
          continue;
        }
      }
      try {
        final l = StrisoAudioLib._(DynamicLibrary.open(p), p);
        final v = l.apiVersion(), ss = l.sizeofStatus(), sd = l.sizeofDevice();
        final se = v >= 2 ? l.sizeofEvent() : 0;
        if (v != _apiVersion || ss != sizeOf<SaStatus>() || sd != sizeOf<SaDevice>() || se != sizeOf<SaEvent>()) {
          tried.add(
            '$p (api $v, status $ss bytes, device $sd bytes, event $se bytes; this app expects api $_apiVersion, ${sizeOf<SaStatus>()}, ${sizeOf<SaDevice>()}, ${sizeOf<SaEvent>()})',
          );
          continue;
        }
        return l;
      } catch (e) {
        tried.add('$p ($e)');
      }
    }
    throw StateError('striso_audio could not be loaded: ${tried.join('; ')}');
  }

  late final apiVersion = lib.lookupFunction<Int32 Function(), int Function()>('sa_api_version');
  late final miniaudioVersion = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('sa_miniaudio_version');
  late final sizeofStatus = lib.lookupFunction<Int32 Function(), int Function()>('sa_sizeof_status');
  late final sizeofDevice = lib.lookupFunction<Int32 Function(), int Function()>('sa_sizeof_device');
  late final sizeofEvent = lib.lookupFunction<Int32 Function(), int Function()>('sa_sizeof_event');
  late final getEvents = lib.lookupFunction<Int32 Function(Uint32, Pointer<SaEvent>, Int32), int Function(int, Pointer<SaEvent>, int)>('sa_get_events');
  late final testJitter = lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('sa_test_jitter');
  late final init = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('sa_init');
  late final shutdown = lib.lookupFunction<Void Function(), void Function()>('sa_shutdown');
  late final enumerate = lib.lookupFunction<Void Function(), void Function()>('sa_enumerate');
  late final deviceCount = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('sa_device_count');
  late final deviceGet = lib.lookupFunction<Int32 Function(Int32, Int32, Pointer<SaDevice>), int Function(int, int, Pointer<SaDevice>)>('sa_device_get');
  late final configure = lib
      .lookupFunction<
        Uint32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int)
      >('sa_configure');
  late final setGain = lib.lookupFunction<Void Function(Float), void Function(double)>('sa_set_gain');
  late final recordStart = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('sa_record_start');
  late final recordStop = lib.lookupFunction<Void Function(), void Function()>('sa_record_stop');
  late final getStatus = lib.lookupFunction<Void Function(Pointer<SaStatus>), void Function(Pointer<SaStatus>)>('sa_get_status');
  late final documentsDir = lib.lookupFunction<Int32 Function(Pointer<Uint8>, Int32), int Function(Pointer<Uint8>, int)>('sa_documents_dir');
  late final requestMic = lib.lookupFunction<Void Function(), void Function()>('sa_request_mic');
  late final selftest = lib
      .lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Uint8>, Int32), int Function(Pointer<Utf8>, Pointer<Uint8>, int)>('sa_selftest');

  /// Runs the native self-test (null backend; no real device). Returns (failures, report).
  (int, String) runSelftest(String dir) {
    final d = dir.toNativeUtf8();
    const size = 65536;
    final buf = calloc<Uint8>(size);
    try {
      final n = selftest(d, buf, size);
      return (n, buf.cast<Utf8>().toDartString());
    } finally {
      calloc.free(d);
      calloc.free(buf);
    }
  }
}

/// SA_BACKEND_*
const backendSystem = 0, backendNull = 1;

class NativeAudioBackend implements AudioBackend {
  final StrisoAudioLib _l;
  final int backend;
  final Pointer<SaStatus> _st = calloc<SaStatus>();
  final Pointer<SaDevice> _dev = calloc<SaDevice>();
  static const _evMax = 128;
  final Pointer<SaEvent> _ev = calloc<SaEvent>(_evMax);
  bool _inited = false;

  NativeAudioBackend(this._l, {this.backend = backendSystem});

  /// The library next to the app, or null (the reason in [loadError]).
  static NativeAudioBackend? tryLoad({String? explicit, int backend = backendSystem}) {
    try {
      loadError = null;
      return NativeAudioBackend(StrisoAudioLib.load(explicit: explicit), backend: backend);
    } catch (e) {
      loadError = '$e';
      return null;
    }
  }

  static String? loadError;

  String get path => _l.path;

  @override
  String get description => 'striso_audio ${_l.apiVersion()}, miniaudio ${_l.miniaudioVersion().toDartString()} (${_l.path})';

  @override
  bool init() {
    if (_inited) return true;
    _inited = _l.init(backend) == 0;
    return _inited;
  }

  @override
  void shutdown() {
    if (!_inited) return;
    _l.shutdown();
    _inited = false;
  }

  @override
  void requestDevices() => _l.enumerate();

  @override
  List<AudioDevice> devices({required bool capture}) {
    final c = capture ? 1 : 0;
    final n = _l.deviceCount(c);
    final out = <AudioDevice>[];
    for (var i = 0; i < n; i++) {
      if (_l.deviceGet(c, i, _dev) != 0) continue;
      final d = _dev.ref;
      out.add(
        AudioDevice(
          _str(d.name, 256),
          id: _str(d.id, 256),
          transport: AudioTransport.of(d.transport),
          devMin: d.dev_min,
          devDefault: d.dev_default,
          isDefault: d.is_default != 0,
          isStriso: d.is_striso != 0,
          nativeBits: d.native_bits,
          nativeRate: d.native_rate,
          nativeChannels: d.native_channels,
        ),
      );
    }
    return out;
  }

  @override
  int configure(AudioConfig c) {
    final i = c.input.toNativeUtf8(), o = c.output.toNativeUtf8();
    try {
      return _l.configure(c.run ? 1 : 0, i, o, c.period, c.monitor ? 1 : 0, (c.exclusive ? 1 : 0) | (c.exclusiveOutput ? 2 : 0));
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  @override
  void setGain(double linear) => _l.setGain(linear);

  @override
  void recordStart(String path) {
    final p = path.toNativeUtf8();
    try {
      _l.recordStart(p);
    } finally {
      calloc.free(p);
    }
  }

  @override
  void recordStop() => _l.recordStop();

  @override
  AudioStatus status() {
    _l.getStatus(_st);
    final s = _st.ref;
    DevState dev(int v) => v >= 0 && v < DevState.values.length ? DevState.values[v] : DevState.failed;
    return AudioStatus(
      initialised: s.initialised != 0,
      configGen: s.config_gen,
      devicesGen: s.devices_gen,
      capture: dev(s.capture_state),
      captureError: s.capture_error,
      captureResult: s.capture_result,
      captureRate: s.capture_rate,
      captureChannels: s.capture_channels,
      capturePeriod: s.capture_period,
      captureBits: s.capture_bits,
      captureCallbacks: s.capture_callbacks,
      captureExclusive: s.capture_exclusive != 0,
      playback: dev(s.playback_state),
      playbackError: s.playback_error,
      playbackResult: s.playback_result,
      playbackRate: s.playback_rate,
      playbackPeriod: s.playback_period,
      playbackPeriods: s.playback_periods,
      playbackCallbacks: s.playback_callbacks,
      playbackExclusive: s.playback_exclusive != 0,
      levelL: s.level_l,
      levelR: s.level_r,
      levelOut: s.level_out,
      gain: s.gain,
      latencyMs: s.latency_ms,
      ringMs: s.ring_ms,
      targetMs: s.target_ms,
      driftPpm: s.drift_ppm,
      underruns: s.underruns,
      overruns: s.overruns,
      resyncs: s.resyncs,
      streaming: s.streaming != 0,
      record: s.record_state >= 0 && s.record_state < RecState.values.length ? RecState.values[s.record_state] : RecState.stopped,
      recordError: s.record_error,
      recordBits: s.record_bits,
      recordFrames: s.record_frames,
      recordDropped: s.record_dropped,
      micPermission: s.mic_permission,
      captureBuffer: s.capture_buffer,
      captureDevMin: s.capture_dev_min,
      captureDevDefault: s.capture_dev_default,
      captureStreamLatency: s.capture_stream_latency,
      captureExclResult: s.capture_excl_result,
      playbackBuffer: s.playback_buffer,
      playbackDevMin: s.playback_dev_min,
      playbackDevDefault: s.playback_dev_default,
      playbackStreamLatency: s.playback_stream_latency,
      playbackExclResult: s.playback_excl_result,
      playbackTransport: AudioTransport.of(s.playback_transport),
      inMs: s.in_ms,
      outMs: s.out_ms,
      marginMs: s.margin_ms,
      inLate: s.in_late,
      outLate: s.out_late,
      outGlitches: s.out_glitches,
      servoLimits: s.servo_limits,
      retargets: s.retargets,
      eventsLost: s.events_lost,
      capNominalUs: s.cap_nominal_us,
      capMaxGapUs: s.cap_max_gap_us,
      capRecentGapUs: s.cap_recent_gap_us,
      capBurst: s.cap_burst,
      capBurstMax: s.cap_burst_max,
      playNominalUs: s.play_nominal_us,
      playMaxGapUs: s.play_max_gap_us,
      playRecentGapUs: s.play_recent_gap_us,
      playBurst: s.play_burst,
      playBurstMax: s.play_burst_max,
      nowUs: s.now_hi * 4294967296 + s.now_lo,
      eventSeq: s.event_seq,
      rtCapture: s.rt_capture,
      rtPlayback: s.rt_playback,
      rtControl: s.rt_control,
      timer1ms: s.timer_1ms != 0,
      powerThrottlingOff: s.power_throttling_off != 0,
    );
  }

  @override
  List<AudioEvent> events(int afterSeq) {
    final out = <AudioEvent>[];
    var after = afterSeq;
    for (var round = 0; round < 8; round++) {
      final n = _l.getEvents(after, _ev, _evMax);
      for (var i = 0; i < n; i++) {
        final e = (_ev + i).ref;
        out.add(AudioEvent(e.seq, e.type, e.t_hi * 4294967296 + e.t_lo, e.a, e.b, e.c));
        after = e.seq;
      }
      if (n < _evMax) break;
    }
    return out;
  }

  /// Tests on the null backend: late callbacks (see sa_test_jitter).
  void testJitter(int maxLateUs, int everyN, {bool output = false}) => _l.testJitter(maxLateUs, everyN, output ? 1 : 0);

  @override
  String? documentsDir() {
    const size = 4096;
    final buf = calloc<Uint8>(size);
    try {
      final n = _l.documentsDir(buf, size);
      return n > 0 ? buf.cast<Utf8>().toDartString(length: n) : null;
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void requestMic() => _l.requestMic();
}
