// The flows of docs/flows.md on the Dart mock (no USB, no window): the start screen, a problem
// with its fixes in the banner and on the board, Virtual started from a fix, the header's one
// button (Stop), the build row and menu, Stop.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/theme.dart';

Future<AppController> boot(WidgetTester tester, AppController ctl, {Size size = const Size(1600, 1100)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(StrisoLiveApp(ctl));
  await tester.pump();
  return ctl;
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t < ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Real time passes for the mock board's stopwatch; fake time for the timers.
Future<void> runFor(WidgetTester tester, int ms) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await settle(tester, 200);
}

Future<void> untilLive(WidgetTester tester, AppController ctl) async {
  for (var i = 0; i < 60 && (ctl.listsLoading || ctl.dot != Dot.demo); i++) {
    await runFor(tester, 50);
  }
  expect(ctl.connected, isTrue);
}

Future<T> pumpUntil<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T value;
  f.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (!done) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(done, isTrue, reason: 'did not finish');
  return value;
}

Future<void> finish(WidgetTester tester, AppController ctl) async {
  await pumpUntil(tester, ctl.endSession());
  await settle(tester, 7000);
  await tester.pumpWidget(const SizedBox());
  ctl.dispose();
}

void main() {
  testWidgets('start screen, a problem with its fix, Virtual from the fix, Stop', (tester) async {
    final ctl = await boot(tester, AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store.memory()));
    // nothing plays: the start screen offers Virtual; the header has no button, the segments act
    expect(find.text('Plug in your Striso'), findsOneWidget);
    expect(find.byKey(const Key('fix-playVirtual')), findsOneWidget);
    expect(find.byKey(const Key('btn-connect')), findsNothing);
    expect(ctl.status, 'Not connected');

    // the Striso segment without USB: a problem, in the banner and on the board, with its fix
    await tester.tap(find.byKey(const Key('mode-striso')));
    await settle(tester, 300);
    expect(ctl.state, isA<Failed>());
    expect(ctl.problem!.title, 'USB is off in this run');
    expect(find.byKey(const Key('problem-title')), findsOneWidget, reason: 'the banner strip');
    expect(find.byKey(const Key('invite-title')), findsOneWidget, reason: 'the start screen');
    expect(find.text('USB is off in this run'), findsAtLeastNWidgets(2), reason: 'the banner, the start screen (and the status)');
    expect(ctl.status, 'USB is off in this run');
    expect(ctl.banner, isNull, reason: 'no prose banner for a session failure');

    // the fix plays Virtual
    await tester.tap(find.byKey(const Key('fix-playVirtual')).first);
    await untilLive(tester, ctl);
    await settle(tester);
    expect(ctl.problem, isNull);
    expect(find.byKey(const Key('problem-title')), findsNothing);
    expect(find.byKey(const Key('invite')), findsNothing);
    expect(ctl.isVirtual, isTrue);
    expect(ctl.connectLabel, 'Stop');
    expect(find.widgetWithText(Btn, 'Stop'), findsOneWidget);
    expect(find.byKey(const Key('demo-chip')), findsOneWidget);
    // Virtual's left column starts with the build it runs
    expect(find.byKey(const Key('build-menu')), findsOneWidget);
    expect(find.text('The Dart mock'), findsOneWidget);
    expect(find.byKey(const Key('build-swap')), findsNothing, reason: 'no build played before this one');
    // Setup: Save names the instrument; the firmware row says what plays
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, 300);
    expect(find.text('Save to Virtual'), findsOneWidget);
    expect(find.text('Other builds: Play, the build row.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-play')));
    await settle(tester, 300);

    // Stop: nothing plays; the Striso is not touched; the start screen offers both
    await tester.tap(find.byKey(const Key('btn-connect')));
    await pumpUntil(tester, Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester, 500);
    expect(ctl.state, isA<Idle>());
    expect((ctl.state as Idle).why, IdleWhy.stopped);
    expect(ctl.status, 'Stopped');
    expect(ctl.connectLabel, '');
    expect(find.byKey(const Key('btn-connect')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('invite-title'))).data, 'Stopped');
    expect(find.byKey(const Key('fix-connectStriso')), findsOneWidget);
    expect(find.byKey(const Key('fix-playVirtual')), findsOneWidget);
    expect(ctl.session.resources.isEmpty, isTrue, reason: 'nothing runs after Stop');
    await finish(tester, ctl);
  });

  testWidgets('the build menu: titles from manifest.json, folder names otherwise; a build that does not load is greyed with why', (tester) async {
    final dir = Directory.systemTemp.createTempSync('flows_fw');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final sep = Platform.pathSeparator;
    final fw = Directory('${dir.path}${sep}firmware')..createSync();
    final sax = Directory('${fw.path}${sep}2026-10-24_audition sax v1 (56f7266)')..createSync();
    File('${sax.path}$sep${virtualLibName()}').writeAsStringSync('not a library');
    File('${sax.path}${sep}manifest.json').writeAsStringSync(
      jsonEncode({
        'name': 'striso_virtual',
        'version': '2026-10-24_audition sax v1 (56f7266)',
        'platform': virtualPlatform(),
        'library': virtualLibName(),
        'sha256': '00',
        'api_version': 2,
        'firmware_version': '2026-10-25_v2.2.4-299-g56f7266_all',
        'title': 'Sax v1',
        'description': 'Soprano, alto, tenor and baritone on the wind key.',
      }),
    );
    final rel = Directory('${fw.path}${sep}2026-10-25_v2.2.4-308-g3e05282_all')..createSync();
    File('${rel.path}$sep${virtualLibName()}').writeAsStringSync('not a library either');

    // the newest build chosen by hand (a STRISO_VIRTUAL_LIB in the environment would win otherwise); the mock plays
    final ctl = AppController(
      options: AppOptions(noUsb: true, mockDemo: true, virtualLib: '${rel.path}$sep${virtualLibName()}'),
      store: Store('${dir.path}${sep}settings.json'),
    );
    expect(ctl.firmwareDir, fw.path);
    final list = ctl.buildList();
    expect(list.map((b) => b.title), ['2026-10-25_v2.2.4-308-g3e05282_all', 'Sax v1'], reason: 'newest folder first; the manifest names the sax');
    expect(list.last.build.description, startsWith('Soprano'));
    expect(list.every((b) => !b.loadable), isTrue, reason: 'fake bytes are no library');
    expect(list.first.current, isTrue, reason: 'the newest build is the one chosen when none was');

    await boot(tester, ctl);
    await tester.tap(find.byKey(const Key('fix-playVirtual')));
    await untilLive(tester, ctl);
    await settle(tester);
    await tester.tap(find.byKey(const Key('build-menu')));
    await settle(tester, 400);
    expect(find.text('Sax v1'), findsOneWidget);
    final item = tester.widget<PopupMenuItem<String>>(find.byKey(const Key('build-2026-10-24_audition sax v1 (56f7266)')));
    expect(item.enabled, isFalse, reason: 'cannot be chosen: it does not load');
    expect(find.text('Install a release zip…'), findsOneWidget);
    expect(find.text('Open the firmware folder'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await settle(tester, 400);
    await finish(tester, ctl);
  });
}
