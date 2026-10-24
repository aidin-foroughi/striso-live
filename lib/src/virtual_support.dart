// The virtual Striso in the app (striso_virtual: the firmware's own code on the PC):
//   Virtual: what Demo was. The virtual board behind the same Transport as the USB board, played
//     by hand on the board view; it saves to its own flash through its bootloader's drive. The
//     Dart mock stands in only when the native library does not load (labelled so).
//   Audition: a firmware build played live with the real Striso as the controller, without
//     flashing it. The real board's stream (StcS) goes into the virtual board's key injection, the
//     virtual board renders in the output's callback (the audio engine's output-only source), the
//     real board's own synth is muted (its effects' output level) until the audition ends. The app
//     then talks to the virtual board: live parameters, presets and settings keys act on it.
// A build: --virtual-lib=PATH (striso_virtual.dll, .dylib or .so) or $STRISO_VIRTUAL_LIB.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'controller.dart';

class VirtualSupport {
  final AppController ctl;
  String? libPath;
  final bool mockOnly;

  VirtualBoard? board;
  VirtualPlayer? player;
  String? loadError;
  StrisoVirtualLib? _lib;

  // the audition
  StrisoClient? _real;
  RealBoardMute? _mute;
  AuditionOutput? _out;
  bool _throughWas = false;
  bool auditioning = false;

  /// Widget tests keep the Dart mock unless they name a build.
  VirtualSupport(this.ctl, {this.libPath, bool mockOnly = false})
    : mockOnly = mockOnly || (libPath == null && Platform.environment['FLUTTER_TEST'] == 'true');

  /// The library (the build given, or the one found), loaded once; null with [loadError].
  StrisoVirtualLib? get lib {
    if (_lib != null || mockOnly) return _lib;
    try {
      _lib = StrisoVirtualLib.load(explicit: libPath);
      loadError = null;
    } catch (e) {
      loadError = '$e';
    }
    return _lib;
  }

  bool get available => lib != null;

  /// The firmware build the virtual board runs (date, git describe, _all).
  String? get version => _lib?.firmwareVersion;

  /// The virtual board session runs (not the Dart mock).
  bool get isVirtual => board != null && !board!.disposed;

  /// The header and status texts.
  String get pill => auditioning ? 'Virtual' : (isVirtual ? 'Virtual' : 'Demo (mock)');
  String get sessionLabel => auditioning
      ? 'Playing: virtual ${version ?? ''} with your Striso'
      : (isVirtual ? 'Virtual Striso${version != null ? ' ($version)' : ''}' : 'Demo (the Dart mock: the virtual board did not load)');

  /// The Virtual session's transport: the virtual board (booted on first use, in real time), or
  /// the Dart mock when the library is not there.
  Transport demoTransport() {
    if (lib == null) {
      ctl.log('virtual board: ${loadError ?? 'off (--mock-demo)'}; the Dart mock instead');
      return MockTransport();
    }
    if (board == null || board!.disposed) {
      board = VirtualBoard(libPath: _lib!.path)..startRealtime();
      player = VirtualPlayer(board!);
      ctl.log('virtual board: ${_lib!.path}, firmware $version');
    } else if (!board!.realtime) {
      board!.startRealtime();
    }
    return VirtualBoardTransport(board!);
  }

  /// The bootloader's drive of the virtual board (Save to Striso).
  List<String> driveRoots() {
    final p = board?.drivePath;
    return p == null ? const [] : [p];
  }

  /// After a save or a reset: the virtual board back on its USB, a new session.
  Future<bool> reconnect() async {
    final b = board;
    if (b == null) return false;
    final sw = Stopwatch()..start();
    while (!b.attached && sw.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!b.attached) return false;
    return (await ctl.startSession(VirtualBoardTransport(b), ConnMode.demo)) == true;
  }

  // --- the audition -----------------------------------------------------------------------------

  /// A Striso on USB and a build to play.
  bool get canAudition => !auditioning && ctl.mode == ConnMode.usb && ctl.client != null && available && ctl.audio.backend != null;

  /// Plays the virtual board (the build at [path], else the one loaded) with the real Striso.
  Future<bool> startAudition({String? path}) async {
    if (auditioning) return true;
    if (path != null && path != libPath) {
      await stopBoard();
      libPath = path;
      _lib = null;
    }
    final real = ctl.client;
    final backend = ctl.audio.backend;
    if (real == null || ctl.mode != ConnMode.usb || backend == null || lib == null) {
      ctl.toast(lib == null ? 'The virtual board did not load: ${loadError ?? ''}' : 'Connect the Striso first', 'warn');
      return false;
    }
    final audioLib = _audioLibrary();
    _out = audioLib == null ? null : AuditionOutput.of(audioLib);
    if (_out == null) {
      ctl.toast('This audio engine has no output source (sa_set_source): the audition needs it', 'warn');
      return false;
    }
    // the real board: muted, streaming into the virtual one, out of the controller's hands
    _mute = RealBoardMute(real);
    if (!await _mute!.mute()) ctl.log('audition: the board has no effects level to mute it with');
    await stopBoard();
    board = VirtualBoard(libPath: _lib!.path, serial: 2);
    player = VirtualPlayer(board!);
    final feed = AuditionFeed(board!);
    _real = ctl.releaseClient();
    _real!.onStream = (src, id, v, n) {
      feed.onStream(src, id, v, n);
      ctl.live.apply(src, id, v, n, clockMs());
    };
    _real!.closed.listen((_) => stopAudition(reconnect: false));
    if (!_real!.streaming) unawaited(_real!.startStream());
    // the output alone, the virtual board rendering in its callback
    _throughWas = ctl.audio.through;
    if (_throughWas) ctl.audio.setThrough(false);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // Through PC lets go of the devices
    // (sa_init starts the engine afresh: the source goes on after it)
    if (!backend.init()) {
      ctl.toast('The computer’s audio system did not start: the audition has no sound', 'warn');
    }
    _out!.attach(board!);
    _out!.open(output: ctl.audio.prefs.output ?? '', period: 144, exclusive: Platform.isWindows);
    auditioning = true;
    ctl.log('audition: ${_lib!.path} (firmware $version); the board is muted');
    final ok = (await ctl.startSession(VirtualBoardTransport(board!), ConnMode.demo)) == true;
    if (!ok) {
      await stopAudition();
      return false;
    }
    return true;
  }

  /// Back to the real Striso: its synth unmuted, the app connected to it again.
  Future<void> stopAudition({bool reconnect = true}) async {
    if (!auditioning) return;
    auditioning = false;
    await ctl.endSession(quiet: true);
    _out?.open(run: false);
    _out?.detach();
    _out = null;
    if (_throughWas) ctl.audio.setThrough(true);
    final real = _real;
    _real = null;
    if (real != null) {
      await _mute?.restore();
      await real.disconnect();
    }
    _mute = null;
    await stopBoard();
    ctl.log('audition ended');
    if (reconnect) unawaited(ctl.userConnect());
  }

  Future<void> stopBoard() async {
    player?.dispose();
    player = null;
    board?.dispose();
    board = null;
  }

  DynamicLibrary? _audioLibrary() {
    for (final p in strisoAudioCandidates()) {
      try {
        if ((p.contains('/') || p.contains(Platform.pathSeparator)) && !File(p).existsSync()) continue;
        return DynamicLibrary.open(p);
      } catch (_) {}
    }
    return null;
  }

  Future<void> dispose() async {
    if (auditioning) await stopAudition(reconnect: false);
    await stopBoard();
  }
}
