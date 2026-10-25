// The virtual Striso: the firmware compiled for the computer (the striso_virtual library, loaded
// at run time: the app ships no firmware), a standalone soft instrument. It holds no USB session
// with any board. Its console is a Board like the Striso's; its sound renders in the output's
// callback (SoundRouting); MIDI controllers play it through its own USB-MIDI input
// (sv_midi_write). Its config flash is kept on this computer and boots the next one.
// Widget tests without a library run the Dart mock instead (labelled so).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'session/board.dart';
import 'session/session.dart';
import 'session/session_machine.dart';

/// What SoundRouting needs of the instrument: its clock and its render callback.
abstract class VirtualSound {
  bool get realtime;
  void startRealtime();
  void stopRealtime();
  int get timeFrames;

  /// sv_audio_source and its board, as addresses for sa_set_source.
  int get sourceFn;
  int get sourceUser;

  /// sv_midi_write and its board, as addresses for the MIDI sink.
  int get midiFn;
  int get midiUser;

  /// sv_ump_write and its board, as addresses for the UMP sink (MIDI 2.0 inputs).
  int get umpFn;
  bool get alive;
}

class VirtualInstrument implements VirtualSound {
  final VirtualBoard board;
  final VirtualPlayer player;
  VirtualInstrument(this.board) : player = VirtualPlayer(board);

  @override
  bool get realtime => board.realtime;
  @override
  void startRealtime() {
    if (!board.disposed && !board.realtime) board.startRealtime();
  }

  @override
  void stopRealtime() {
    if (!board.disposed && board.realtime) board.stopRealtime();
  }

  @override
  int get timeFrames => board.disposed ? 0 : board.timeFrames;
  @override
  int get sourceFn => board.lib.audioSource.address;
  @override
  int get sourceUser => board.handle.address;
  @override
  int get midiFn => board.lib.midiSink.address;
  @override
  int get midiUser => board.handle.address;
  @override
  int get umpFn => board.lib.umpSink.address;
  @override
  bool get alive => !board.disposed;
}

class _VirtualBoardHandle extends Board {
  final VirtualInstrument inst;
  @override
  final String label;
  @override
  final StrisoClient client;
  _VirtualBoardHandle(this.inst, this.label) : client = StrisoClient(VirtualBoardTransport(inst.board));

  @override
  Mode get mode => Mode.virtual;
  @override
  PlayableBoard? get hand => inst.player;
  @override
  List<String>? get saveRoots {
    final p = inst.board.drivePath;
    return p == null ? const [] : [p];
  }

  @override
  Future<void> close() async {
    inst.player.releaseAll();
    try {
      await client.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

class VirtualStrisoRuntime implements VirtualRuntime {
  /// The build chosen (its library's path), or null for none.
  String? libPath;

  /// How the user knows the build (its manifest's title, else its folder's name); the label.
  String? buildTitle;

  /// --mock-demo: the Dart mock whatever library there is.
  final bool forceMock;

  /// The Dart mock instead of a library: forced, or a widget test that names no library.
  bool get mockOnly =>
      forceMock || (libPath == null && Platform.environment['FLUTTER_TEST'] == 'true' && Platform.environment['STRISO_VIRTUAL_LIB'] == null);

  /// Where the instrument's config flash is kept (null: not kept, tests).
  final String? flashFile;
  final void Function(String) log;

  StrisoVirtualLib? _lib;

  /// Why [libPath] did not load (null: it did, or there is none). Set once per choice: a build
  /// that failed is not tried again until it is chosen again.
  LoadFailure? failure;
  VirtualInstrument? instrument;
  MockBoard? mock;

  /// The instrument changed (started, stopped): SoundRouting attaches or detaches it.
  final void Function()? onChanged;

  VirtualStrisoRuntime({String? libPath, String? title, bool mockOnly = false, this.flashFile, required this.log, this.onChanged})
    : forceMock = mockOnly {
    selectLibrary(libPath, title: title);
  }

  /// The library chosen and loaded; null with [failure], or when none is chosen.
  StrisoVirtualLib? get lib => _lib;

  bool get available => _lib != null;

  /// Chooses [path] (null: none) and loads it now; returns why it did not load, if so. The
  /// instrument must be stopped (the session tears down first); the old library is let go of
  /// (DynamicLibrary.close) so a rebuilt file at the same path loads afresh.
  LoadFailure? selectLibrary(String? path, {String? title}) {
    if (instrument != null) throw StateError('stop the virtual Striso before switching its firmware');
    final old = _lib;
    _lib = null;
    failure = null;
    if (old != null) StrisoVirtualLib.unload(old.path);
    libPath = path;
    buildTitle = title;
    if (path == null || mockOnly) return null;
    try {
      _lib = StrisoVirtualLib.load(explicit: path);
    } on LoadFailure catch (e) {
      failure = e;
    } catch (e) {
      failure = LoadFailure(LoadFailureKind.other, path, '$e');
    }
    return failure;
  }

  /// The firmware the library runs (sv_firmware_version: what StcV says first).
  String? get version => _lib?.firmwareVersion;
  bool get isMock => instrument == null && mock != null;
  VirtualSound? get sound => instrument;

  /// For the status and the log: the build as the user knows it.
  String get label => isMock ? 'Demo (mock)' : 'Virtual · ${buildTitle ?? (version != null ? shortVersion(version!) : 'no build')}';

  @override
  Future<Board> open() async {
    if (mockOnly) {
      mock ??= MockBoard();
      return TransportBoard(Mode.virtual, MockTransport(board: mock), label: 'Demo (mock)', hand: mock);
    }
    final l = _lib;
    if (l == null) throw VirtualError(failure?.message ?? 'No firmware build is chosen for Virtual.');
    var inst = instrument;
    if (inst == null || !inst.alive) {
      final flash = _readFlash();
      final b = VirtualBoard(libPath: l.path, flash: flash);
      b.startRealtime(); // its own clock until the output takes it over
      inst = instrument = VirtualInstrument(b);
      log('virtual: ${l.path}, firmware ${l.firmwareVersion}${flash != null ? ', its settings from $flashFile' : ''}');
      onChanged?.call();
      if (!await waitBack()) throw const VirtualError('The virtual Striso did not start.');
    }
    return _VirtualBoardHandle(inst, label);
  }

  @override
  Future<bool> waitBack() async {
    final b = instrument?.board;
    if (b == null) return mock != null;
    final sw = Stopwatch()..start();
    while (!b.disposed && !b.attached && sw.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return !b.disposed && b.attached;
  }

  @override
  Future<void> stop() async {
    mock = null;
    final inst = instrument;
    if (inst == null) return;
    instrument = null;
    onChanged?.call(); // SoundRouting detaches the source (it waits for the callback to leave it)
    keepFlash(inst);
    inst.player.dispose();
    inst.board.dispose();
    log('virtual: stopped');
  }

  Uint8List? _readFlash() {
    final f = flashFile;
    if (f == null) return null;
    try {
      final file = File(f);
      return file.existsSync() ? file.readAsBytesSync() : null;
    } catch (e) {
      log('virtual: could not read $f: $e');
      return null;
    }
  }

  /// The instrument's config flash to disk (after Save, and when it stops).
  void keepFlash([VirtualInstrument? inst]) {
    final f = flashFile, b = (inst ?? instrument)?.board;
    if (f == null || b == null || b.disposed) return;
    try {
      File(f).parent.createSync(recursive: true);
      File(f).writeAsBytesSync(b.flash, flush: true);
    } catch (e) {
      log('virtual: could not keep its settings in $f: $e');
    }
  }
}

/// "2026-10-24 v2.2.4-80-ga647e81" -> "a647e81" (the commit), else the version as it is.
String shortVersion(String v) {
  final m = RegExp(r'-g([0-9a-f]{7,})').firstMatch(v);
  if (m != null) return m.group(1)!;
  final parts = v.trim().split(RegExp(r'\s+'));
  return parts.length > 1 ? parts[1] : v;
}
