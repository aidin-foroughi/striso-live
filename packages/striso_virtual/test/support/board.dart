// A virtual board running by itself with striso_core's client on its console, for the client's
// tests: what the firmware answers is what they expect. They skip when the library is not built
// (found through $STRISO_VIRTUAL_LIB, $STRISO_FW_DIR or ../striso-control-firmware).
import 'dart:async';
import 'dart:io';

import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

/// Why the tests skip: the library is not there (null: it is).
String? get libraryMissing {
  try {
    StrisoVirtualLib.load();
    return null;
  } catch (e) {
    return 'striso_virtual not built: $e';
  }
}

/// A board with the factory settings, running in real time; the client connected to it. Both go
/// when the test ends (passed or not: a board left running would outlive its library).
Future<(VirtualBoard, StrisoClient)> boot({String? moduleStore}) async {
  final b = VirtualBoard(moduleStore: moduleStore)..startRealtime();
  final c = StrisoClient(VirtualBoardTransport(b));
  addTearDown(() => shutDown(b, c));
  await c.connect();
  return (b, c);
}

/// The client off, the board gone (again: nothing).
Future<void> shutDown(VirtualBoard b, StrisoClient c) async {
  await c.disconnect();
  b.dispose();
}

/// An engine package with this PC's image by its engine's id (`<id>.awvapkg`): from
/// $STRISO_PACKAGE_DIR, or the firmware build's test packages; null when there is none.
String? testPackage(String id) {
  final fw = Platform.environment['STRISO_FW_DIR'];
  final libPath = Platform.environment['STRISO_VIRTUAL_LIB'];
  for (final d in [
    ?Platform.environment['STRISO_PACKAGE_DIR'],
    if (fw != null) for (final b in ['host-virtual', 'host']) '$fw/build/$b/virtual/tests/packages',
    if (libPath != null) '${File(libPath).parent.path}/tests/packages',
  ]) {
    final f = File('$d/$id.awvapkg');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// Waits for [cond], polling.
Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met in $timeout');
    await sleep(5);
  }
}
