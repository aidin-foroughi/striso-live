// A virtual Striso board: the firmware's own code (striso-control-firmware's striso_virtual) on
// the PC. See striso_virtual.h for what runs and how; this is its Dart face.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

class VirtualLeds {
  /// The indicator's colour as last set (0..255 each), and its PWM duty now (shows blinks).
  final List<int> rgb, pwm;

  /// up2, up, down, down2: [svLedOff], [svLedDim], [svLedOn].
  final List<int> updown;
  final bool led1;
  const VirtualLeds(this.rgb, this.pwm, this.updown, this.led1);
  int get rgbHex => (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
  @override
  String toString() => 'VirtualLeds(#${rgbHex.toRadixString(16).padLeft(6, '0')}, updown $updown)';
}

class VirtualState {
  final int usb, voice, voices, midiMode, resets, blocks, toBlock, underruns;
  final bool streaming;
  final double volume;

  /// The voices' controls the engine got last block: note, pres, vpres, but_x, but_y.
  final List<List<double>> controls;
  final List<double> globals;
  const VirtualState({
    required this.usb,
    required this.voice,
    required this.voices,
    required this.midiMode,
    required this.resets,
    required this.blocks,
    required this.toBlock,
    required this.underruns,
    required this.streaming,
    required this.volume,
    required this.controls,
    required this.globals,
  });
}

class VirtualBoard {
  final StrisoVirtualLib lib;
  Pointer<Void> _b;
  final Pointer<Uint8> _io = calloc<Uint8>(65536);
  final Pointer<Float> _audio = calloc<Float>(2 * 48000);
  bool _realtime = false;

  VirtualBoard._(this.lib, this._b);

  /// Boots a board (power on, [bootMs] of virtual time). [flash]: the config area to start with
  /// (from [flash] of an earlier board), else erased (the firmware's defaults). [driveDir]: where
  /// the bootloader's update drive appears (default: a temporary directory). [engineDir]: a
  /// folder of engine components the firmware loads (sv_options.engine_dir), null: none.
  factory VirtualBoard({
    Uint8List? flash,
    String? driveDir,
    bool portKeyHeld = false,
    int serial = 1,
    int bootMs = 1000,
    String? libPath,
    String? engineDir,
  }) {
    final lib = StrisoVirtualLib.load(explicit: libPath);
    final o = calloc<SvOptions>();
    Pointer<Uint8> f = nullptr;
    Pointer<Utf8> d = nullptr, e = nullptr;
    try {
      o.ref.size = sizeOf<SvOptions>();
      if (flash != null) {
        f = calloc<Uint8>(flash.length);
        f.asTypedList(flash.length).setAll(0, flash);
        o.ref.flash = f;
        o.ref.flashLen = flash.length;
      }
      if (driveDir != null) {
        d = driveDir.toNativeUtf8();
        o.ref.driveDir = d.cast();
      }
      if (engineDir != null) {
        e = engineDir.toNativeUtf8();
        o.ref.engineDir = e.cast();
      }
      o.ref.portKeyHeld = portKeyHeld ? 1 : 0;
      o.ref.serial = serial;
      o.ref.bootMs = bootMs <= 0 ? -1 : bootMs;
      final b = lib.create(o);
      if (b == nullptr) throw StateError('sv_create: ${cString(lib.lastError())}');
      return VirtualBoard._(lib, b);
    } finally {
      if (f != nullptr) calloc.free(f);
      if (d != nullptr) calloc.free(d);
      if (e != nullptr) calloc.free(e);
      calloc.free(o);
    }
  }

  bool get disposed => _b == nullptr;

  /// The native sv_board* (for sv_audio_source's user pointer).
  Pointer<Void> get handle => _h;

  void dispose() {
    if (_b == nullptr) return;
    lib.destroy(_b);
    _b = nullptr;
    calloc.free(_io);
    calloc.free(_audio);
  }

  Pointer<Void> get _h {
    if (_b == nullptr) throw StateError('the virtual board is disposed');
    return _b;
  }

  String get firmwareVersion => lib.firmwareVersion;

  // --- time and audio ------------------------------------------------------------------------------

  /// Runs [frames] of virtual time; the USB audio (interleaved stereo, the board's samples / 2^31).
  Float32List render(int frames) {
    final out = Float32List(frames * 2);
    for (var done = 0; done < frames;) {
      final n = frames - done > 48000 ? 48000 : frames - done;
      final r = lib.render(_h, _audio, n);
      if (r < 0) throw StateError(r == svEBusy ? 'the board runs in real time' : 'sv_render: $r');
      out.setRange(2 * done, 2 * (done + n), _audio.asTypedList(2 * n));
      done += n;
    }
    return out;
  }

  /// The engine's mono output (before the effects and the volume) for [frames].
  Float32List renderEngine(int frames) {
    final out = Float32List(frames);
    final p = calloc<Float>(frames);
    try {
      final r = lib.renderTaps(_h, frames, nullptr, p, nullptr);
      if (r < 0) throw StateError('sv_render_taps: $r');
      out.setAll(0, p.asTypedList(frames));
    } finally {
      calloc.free(p);
    }
    return out;
  }

  void advanceMs(int ms) {
    final r = lib.advanceMs(_h, ms);
    if (r < 0) throw StateError(r == svEBusy ? 'the board runs in real time' : 'sv_advance_ms: $r');
  }

  int get timeFrames => lib.timeFrames(_h);

  /// A library thread runs the board with the wall clock; its audio collects for [readAudio].
  void startRealtime({int fifoFrames = 0}) {
    lib.realtimeStart(_h, fifoFrames);
    _realtime = true;
  }

  void stopRealtime() {
    lib.realtimeStop(_h);
    _realtime = false;
  }

  bool get realtime => _realtime;

  /// Up to [maxFrames] of the real-time audio (interleaved stereo).
  Float32List readAudio([int maxFrames = 48000]) {
    final n = lib.readAudio(_h, _audio, maxFrames > 48000 ? 48000 : maxFrames);
    return Float32List.fromList(_audio.asTypedList(2 * (n < 0 ? 0 : n)));
  }

  // --- USB ------------------------------------------------------------------------------------------

  int get usbState => lib.usbState(_h);
  bool get attached => usbState == svUsbAttached;
  bool get inBootloader => usbState == svUsbBootloader;
  int get usbGeneration => lib.usbGeneration(_h);

  /// Bytes to the board's console; false when it is not attached.
  bool consoleWrite(List<int> bytes) {
    for (var off = 0; off < bytes.length;) {
      final n = bytes.length - off > 65536 ? 65536 : bytes.length - off;
      _io.asTypedList(n).setRange(0, n, bytes, off);
      if (lib.consoleWrite(_h, _io, n) < 0) return false;
      off += n;
    }
    return true;
  }

  /// What the board sent since the last read (empty when nothing, null when not attached).
  Uint8List? consoleRead() {
    final b = BytesBuilder(copy: true);
    while (true) {
      final n = lib.consoleRead(_h, _io, 65536);
      if (n < 0) return b.isEmpty ? null : b.takeBytes();
      if (n == 0) break;
      b.add(_io.asTypedList(n));
      if (n < 65536) break;
    }
    return b.takeBytes();
  }

  /// USB-MIDI packets (4 bytes each: cable/CIN, then the message) into the board's USB MIDI in, as
  /// a host sends them; false when it is not attached. (The app's MIDI inputs call sv_midi_write
  /// from the driver's thread; this is the same input for tests.)
  bool midiWrite(List<int> packets) {
    final n = packets.length;
    _io.asTypedList(n).setAll(0, packets);
    return lib.midiWrite(_h, _io, n) >= 0;
  }

  /// Universal MIDI Packets (32-bit words, whole packets) into the board's MIDI 2.0 input
  /// (sv_ump_write): MIDI 2.0 channel voice messages play the synth in their resolution. Returns
  /// the words taken (n), or < 0 (svEBusy: its queue is full, svENoDev: not attached).
  int umpWrite(List<int> words) {
    final n = words.length;
    if (n * 4 > 65536) throw ArgumentError('at most 16384 words at a time');
    _io.cast<Uint32>().asTypedList(n).setAll(0, words);
    return lib.umpWrite(_h, _io.cast<Uint32>(), n);
  }

  /// The board's USB MIDI out: 4-byte USB-MIDI packets.
  Uint8List midiRead() {
    final n = lib.midiRead(_h, _io, 65536);
    return n <= 0 ? Uint8List(0) : Uint8List.fromList(_io.asTypedList(n));
  }

  // --- injection --------------------------------------------------------------------------------------

  /// A key message as the scanner sends it: id 0..67, values in 14 bit steps (8191 = 1.0; a hard
  /// press goes past it: the synth gets it all, the stream saturates); pres 0 releases.
  void injectKey(int id, {required int pres, int velo = 0, int x = 0, int y = 0, int src = 0}) => lib.injectKey(_h, src, id, pres, velo, x, y);

  /// An aux control (IDC_*: 0 portamento, 1 octave up, 2 octave down, 3 settings, 11 pedal...).
  void injectControl(int id, int value) => lib.injectControl(_h, id, value);

  /// The motion sensor's raw reading: gyro x y z, accel x y z (+-2 g, +-500 dps full scale).
  void injectMotion(List<int> raw) {
    final p = calloc<Int16>(6);
    try {
      for (var i = 0; i < 6; i++) {
        p[i] = raw[i];
      }
      lib.injectMotion(_h, p);
    } finally {
      calloc.free(p);
    }
  }

  /// Engine-level controls, bypassing the keys: voice [v]'s note, pres, vpres, but_x, but_y, or
  /// with v = -1 the 8 globals (acc_abs, acc_x, acc_y, acc_z, rot_x, rot_y, rot_z, pedal).
  void setEngineControls(int v, List<double> values) {
    final p = calloc<Float>(8);
    try {
      for (var i = 0; i < values.length && i < 8; i++) {
        p[i] = values[i];
      }
      lib.setEngineControls(_h, v, p);
    } finally {
      calloc.free(p);
    }
  }

  /// synth_select_voice(n) between blocks (the console's voice command does the same).
  bool selectVoice(int n) => lib.selectVoice(_h, n) == 0;

  // --- state ------------------------------------------------------------------------------------------

  VirtualLeds get leds {
    final p = calloc<SvLeds>();
    try {
      lib.getLeds(_h, p);
      final r = p.ref;
      return VirtualLeds([for (var i = 0; i < 3; i++) r.rgb[i]], [for (var i = 0; i < 3; i++) r.pwm[i]], [
        for (var i = 0; i < 4; i++) r.updown[i],
      ], r.led1 != 0);
    } finally {
      calloc.free(p);
    }
  }

  VirtualState get state {
    final p = calloc<SvState>();
    try {
      p.ref.size = sizeOf<SvState>();
      lib.getState(_h, p);
      final r = p.ref;
      return VirtualState(
        usb: r.usb,
        voice: r.voice,
        voices: r.voices,
        midiMode: r.midiMode,
        resets: r.resets,
        blocks: r.blocks,
        toBlock: r.toBlock,
        underruns: r.underruns,
        streaming: r.streaming != 0,
        volume: r.volume,
        controls: [
          for (var v = 0; v < 10; v++) [for (var c = 0; c < 5; c++) r.controls[v][c]],
        ],
        globals: [for (var i = 0; i < 8; i++) r.globals[i]],
      );
    } finally {
      calloc.free(p);
    }
  }

  /// The config area as the board has it (keep it to boot a board with the same settings).
  Uint8List get flash {
    final p = calloc<Uint8>(svFlashSize);
    try {
      final n = lib.getFlash(_h, p, svFlashSize);
      return Uint8List.fromList(p.asTypedList(n < 0 ? 0 : n));
    } finally {
      calloc.free(p);
    }
  }

  /// The bootloader's update drive (a directory) while [inBootloader], else null.
  String? get drivePath {
    final p = calloc<Char>(4096);
    try {
      final n = lib.drivePath(_h, p, 4096);
      return n <= 0 ? null : cString(p);
    } finally {
      calloc.free(p);
    }
  }

  int testHook(int what, [int arg = 0]) => lib.test(_h, what, arg);
}
