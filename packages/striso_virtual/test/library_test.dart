// The virtual Striso is loaded at run time (the app ships no firmware): a library loaded and
// unloaded twice in one process, two builds side by side and switched, a file that is not a
// striso_virtual library or has another C API refused with a clear message.
import 'dart:io';

import 'package:striso_core/striso_core.dart' show Cmd;
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

String? _found() {
  try {
    return StrisoVirtualLib.load().path;
  } catch (_) {
    return null;
  }
}

void main() {
  final lib = _found();
  final skip = lib == null ? 'striso_virtual not built' : null;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sv_lib'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {} // Windows may hold an unloaded DLL's file a moment
  });

  String copy(String name) {
    final d = Directory('${tmp.path}${Platform.pathSeparator}$name')..createSync();
    return File(lib!).copySync('${d.path}${Platform.pathSeparator}${lib.split(RegExp(r'[\\/]')).last}').path;
  }

  /// Boots a board on the library at [path], reads its version over the console, disposes it.
  Future<String> bootOnce(String path) async {
    final b = VirtualBoard(libPath: path)..startRealtime();
    final t = VirtualBoardTransport(b);
    await t.open();
    final got = <int>[];
    final sub = t.data.listen(got.addAll);
    await t.write(Cmd.version());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    await t.close();
    b.dispose();
    return String.fromCharCodes(got);
  }

  test('load, boot, unload, twice in one process: each load a fresh instance', skip: skip, () async {
    final p = copy('a');
    for (var i = 0; i < 2; i++) {
      final l = StrisoVirtualLib.load(explicit: p);
      expect(StrisoVirtualLib.isLoaded(p), isTrue);
      expect(await bootOnce(p), contains(l.firmwareVersion));
      StrisoVirtualLib.unload(p);
      expect(StrisoVirtualLib.isLoaded(p), isFalse);
    }
  });

  test('two builds side by side, then switched', skip: skip, () async {
    final a = copy('build-a'), b = copy('build-b');
    final la = StrisoVirtualLib.load(explicit: a), lb = StrisoVirtualLib.load(explicit: b);
    expect(la.path, isNot(lb.path));
    expect(await bootOnce(a), contains(la.firmwareVersion));
    expect(await bootOnce(b), contains(lb.firmwareVersion));
    StrisoVirtualLib.unload(a);
    expect(await bootOnce(b), contains(lb.firmwareVersion), reason: 'b keeps running after a is gone');
    StrisoVirtualLib.unload(b);
  });

  test('a missing file, a file that is no library, another library: clear errors', skip: skip, () {
    expect(() => StrisoVirtualLib.load(explicit: '${tmp.path}/nothing.dll'), throwsA(predicate((e) => '$e'.contains('not found'))));
    final junk = File('${tmp.path}${Platform.pathSeparator}junk.dll')..writeAsStringSync('not a library');
    expect(() => StrisoVirtualLib.load(explicit: junk.path), throwsA(predicate((e) => '$e'.contains('could not be loaded'))));
    final audio = Platform.environment['STRISO_AUDIO_LIB'];
    if (audio != null && File(audio).existsSync()) {
      expect(() => StrisoVirtualLib.load(explicit: audio), throwsA(predicate((e) => '$e'.contains('not a striso_virtual library'))));
    }
  });

  test('another C API version is refused, with what to do', () {
    expect(StrisoVirtualLib.apiMismatch(svApiVersion), isNull);
    expect(StrisoVirtualLib.apiMismatch(svApiVersion + 1), contains('use a firmware build for this app'));
  });
}
