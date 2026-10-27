// The app's tests on the virtual Striso: the firmware's own code (striso_virtual), as Virtual or as
// the USB Striso. The library is found as the striso_virtual package finds it ($STRISO_VIRTUAL_LIB,
// $STRISO_FW_DIR, ../striso-control-firmware); a test without it skips with [virtualSkip].
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_virtual/striso_virtual.dart';

String? _found() {
  try {
    return StrisoVirtualLib.load().path;
  } catch (_) {
    return null;
  }
}

/// The striso_virtual library the tests run, or null.
final String? virtualLib = _found();

/// The reason to skip a test that needs [virtualLib], or null.
final String? virtualSkip = virtualLib == null ? 'striso_virtual not built (set STRISO_FW_DIR)' : null;

/// A USB backend whose Striso is a virtual board.
class VirtualUsb implements UsbBackend {
  final VirtualBoard board;
  bool present = true;
  int opened = 0, probes = 0;
  VirtualUsb(this.board);
  @override
  Future<({bool present, String where})> probe() async {
    probes++;
    return (present: present && board.attached, where: 'virtual');
  }

  @override
  Transport transport() {
    opened++;
    return VirtualBoardTransport(board);
  }

  @override
  Future<void> dispose() async {}
}

/// A virtual board running on its own clock (dispose it at the end: [disposeBoard]).
Future<VirtualBoard> startBoard(WidgetTester tester) async {
  late VirtualBoard b;
  await tester.runAsync(() async => b = VirtualBoard(libPath: virtualLib)..startRealtime());
  return b;
}

Future<void> disposeBoard(WidgetTester tester, VirtualBoard b) async {
  await tester.runAsync(() async => b.dispose());
}

/// Pumps until [cond]: [step] of fake time per pump, a little real time for the board between.
Future<void> waitFor(WidgetTester tester, bool Function() cond, {int ms = 10000, int step = 20}) async {
  for (var t = 0; t < ms && !cond(); t += step) {
    await tester.pump(Duration(milliseconds: step));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(cond(), isTrue, reason: 'condition not met in $ms ms');
}

/// Lets the app's timers and the board run a while.
Future<void> settle(WidgetTester tester, {int ms = 200}) async {
  for (var t = 0; t < ms; t += 10) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

/// Awaits [f] while fake and real time move on.
Future<T> run<T>(WidgetTester tester, Future<T> f, {int seconds = 10, int step = 20}) async {
  var done = false;
  late T v;
  f.then((x) {
    v = x;
    done = true;
  });
  await waitFor(tester, () => done, ms: seconds * 1000, step: step);
  return v;
}

/// The app in a window of [size] (no USB unless [usb]), Virtual on [virtualLib].
Future<AppController> bootApp(
  WidgetTester tester, {
  AppOptions? options,
  Store? store,
  UsbBackend? usb,
  Size size = const Size(1600, 1500),
  String? backupDir,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ctl = AppController(
    options: options ?? AppOptions(noUsb: usb == null, virtualLib: virtualLib),
    store: store ?? Store.memory(),
    usb: usb,
    backupDir: backupDir ?? '${Directory.systemTemp.path}/striso_live_test_backups',
  );
  await tester.pumpWidget(StrisoLiveApp(ctl));
  await tester.pump();
  return ctl;
}

/// Virtual plays, its lists read.
Future<void> playVirtual(WidgetTester tester, AppController ctl) async {
  await run(tester, ctl.playVirtual());
  await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading && ctl.params[3]!.params.isNotEmpty);
}

/// Ends the session, lets the timers run out, disposes the controller.
Future<void> finish(WidgetTester tester, AppController ctl) async {
  await run(tester, ctl.endSession());
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpWidget(const SizedBox());
  ctl.dispose();
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
}
