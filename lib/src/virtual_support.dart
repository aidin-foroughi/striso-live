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
  /// The library chosen (a path), or null for the first one found.
  String? libPath;
  /// --mock-demo: the Dart mock whatever library there is.
  final bool forceMock;

  /// The Dart mock instead of a library: forced, or a widget test that names no library.
  bool get mockOnly =>
      forceMock || (libPath == null && Platform.environment['FLUTTER_TEST'] == 'true' && Platform.environment['STRISO_VIRTUAL_LIB'] == null);

  /// Where the instrument's config flash is kept (null: not kept, tests).
  final String? flashFile;
  final void Function(String) log;

  StrisoVirtualLib? _lib;
  String? loadError;
  VirtualInstrument? instrument;
  MockBoard? mock;

  /// The instrument changed (started, stopped): SoundRouting attaches or detaches it.
  final void Function()? onChanged;

  VirtualStrisoRuntime({this.libPath, bool mockOnly = false, this.flashFile, required this.log, this.onChanged}) : forceMock = mockOnly;

  /// The library, loaded once; null with [loadError].
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

  /// Another build: the instrument must be stopped (the session tears down first). The old
  /// library is let go of (DynamicLibrary.close); the next [lib] loads [path] afresh.
  void selectLibrary(String? path) {
    if (instrument != null) throw StateError('stop the virtual Striso before switching its firmware');
    final old = _lib;
    _lib = null;
    loadError = null;
    if (old != null) StrisoVirtualLib.unload(old.path);
    libPath = path;
  }

  /// The firmware the library runs (sv_firmware_version: what StcV says first).
  String? get version => _lib?.firmwareVersion;
  bool get isMock => instrument == null && mock != null;
  VirtualSound? get sound => instrument;

  String get label => isMock ? 'Demo (mock)' : 'Virtual Striso${version != null ? ' (${shortVersion(version!)})' : ''}';

  @override
  Future<Board> open() async {
    if (mockOnly) {
      mock ??= MockBoard();
      return TransportBoard(Mode.virtual, MockTransport(board: mock), label: 'Demo (mock)', hand: mock);
    }
    final l = lib;
    if (l == null) throw VirtualError('The virtual Striso did not load: ${loadError ?? 'no striso_virtual library'}');
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
