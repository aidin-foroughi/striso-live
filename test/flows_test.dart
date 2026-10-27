// The flows of docs/flows.md (no USB): the start screen, a problem with its fixes in the banner and
// on the board, Virtual started from a fix on the real firmware (striso_virtual), the header's one
// button (Stop), the build row and menu, Stop.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/session/board.dart' show BoardCapabilities;
import 'package:striso_live/src/theme.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'support/virtual.dart';

void main() {
  testWidgets('start screen, a problem with its fix, Virtual from the fix, Stop', skip: virtualSkip != null, (tester) async {
    final ctl = await bootApp(tester, size: const Size(1600, 1100));
    final build = buildOf(virtualLib!);
    // nothing plays: the start screen offers Virtual; the header has no button, the segments act
    expect(find.text('Plug in your Striso'), findsOneWidget);
    expect(find.byKey(const Key('fix-playVirtual')), findsOneWidget);
    expect(find.byKey(const Key('btn-connect')), findsNothing);
    expect(ctl.status, 'Not connected');

    // the Striso segment without USB: a problem, in the banner and on the board, with its fix
    await tester.tap(find.byKey(const Key('mode-striso')));
    await settle(tester, ms: 300);
    expect(ctl.state, isA<Failed>());
    expect(ctl.problem!.title, 'USB is off in this run');
    expect(find.byKey(const Key('problem-title')), findsOneWidget, reason: 'the banner strip');
    expect(find.byKey(const Key('invite-title')), findsOneWidget, reason: 'the start screen');
    expect(find.text('USB is off in this run'), findsAtLeastNWidgets(2), reason: 'the banner, the start screen (and the status)');
    expect(ctl.status, 'USB is off in this run');
    expect(ctl.banner, isNull, reason: 'no prose banner for a session failure');

    // the fix opens the build chooser: the next thing to choose; choosing plays
    await tester.tap(find.byKey(const Key('fix-playVirtual')).first);
    await settle(tester, ms: 400);
    expect(find.byKey(Key('build-${build.name}')), findsOneWidget, reason: 'the chooser');
    expect(find.byKey(const Key('build-install')), findsOneWidget);
    expect(find.byKey(const Key('build-folder')), findsOneWidget);
    // Esc leaves things as they were
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, ms: 400);
    expect(find.byKey(Key('build-${build.name}')), findsNothing);
    expect(ctl.state, isA<Failed>(), reason: 'nothing started');
    // the header's Virtual opens the same chooser
    await tester.tap(find.byKey(const Key('mode-virtual')));
    await settle(tester, ms: 400);
    await tester.tap(find.byKey(Key('build-${build.name}')));
    await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
    await settle(tester, ms: 600);
    expect(ctl.problem, isNull);
    expect(find.byKey(const Key('problem-title')), findsNothing);
    expect(find.byKey(const Key('invite')), findsNothing);
    expect(ctl.mode, Mode.virtual);
    expect(ctl.caps, BoardCapabilities.virtual);
    expect(ctl.connectLabel, 'Stop');
    expect(find.widgetWithText(Btn, 'Stop'), findsOneWidget);
    expect(find.byKey(const Key('board-tag')), findsOneWidget);
    // the header names the build and reopens the chooser
    expect(tester.widget<Btn>(find.byKey(const Key('mode-virtual'))).label, 'Virtual · ${build.title} ▾');
    expect(find.byKey(const Key('build-swap')), findsNothing, reason: 'no build played before this one');
    // mono: the board's field, switched on the board (key 9), read back; its label is the key's
    expect(ctl.mono, isFalse, reason: 'the firmware starts poly');
    expect(find.byKey(const Key('mono-toggle')), findsOneWidget);
    expect(tester.widget<Toggle>(find.byKey(const Key('mono-toggle'))).label, 'Mono');
    await tester.tap(find.byKey(const Key('mono-toggle')));
    await waitFor(tester, () => ctl.mono == true, ms: 2000);
    await settle(tester, ms: 100);
    expect(tester.widget<Toggle>(find.byKey(const Key('mono-toggle'))).value, isTrue);
    // Setup: Save names the instrument; the firmware row says what plays
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, ms: 300);
    expect(find.text('Save to Virtual'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-play')));
    await settle(tester, ms: 300);

    // Stop: nothing plays; the Striso is not touched; the start screen offers both
    await tester.tap(find.byKey(const Key('btn-connect')));
    await waitFor(tester, () => ctl.state is Idle);
    await settle(tester, ms: 500);
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

  testWidgets('the build menu: titles from manifest.json, folder names otherwise; a build that does not load is greyed with why; one that does plays', skip: virtualSkip != null, (
    tester,
  ) async {
    final dir = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('flows_fw')))!;
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
    // and a real build (this run's striso_virtual), the oldest
    final real = Directory('${fw.path}${sep}2026-10-23_this run')..createSync();
    File(virtualLib!).copySync('${real.path}$sep${virtualLibName()}');

    // the newest build chosen by hand (a STRISO_VIRTUAL_LIB in the environment would win otherwise)
    final ctl = await bootApp(
      tester,
      options: AppOptions(noUsb: true, virtualLib: '${rel.path}$sep${virtualLibName()}'),
      store: Store('${dir.path}${sep}settings.json'),
      size: const Size(1600, 1100),
    );
    expect(ctl.firmwareDir, fw.path);
    final list = ctl.buildList();
    expect(list.map((b) => b.title), ['2026-10-25_v2.2.4-308-g3e05282_all', 'Sax v1', '2026-10-23_this run'], reason: 'newest folder first; the manifest names the sax');
    expect(list[1].build.description, startsWith('Soprano'));
    expect(list.map((b) => b.loadable), [false, false, true], reason: 'fake bytes are no library');
    expect(list.last.commit, commitOf(StrisoVirtualLib.probe(virtualLib!).firmwareVersion), reason: 'the commit its firmware reports');
    expect(list.first.current, isTrue, reason: 'the build chosen');

    await tester.tap(find.byKey(const Key('mode-virtual')));
    await settle(tester, ms: 400);
    expect(find.text('Sax v1'), findsOneWidget);
    expect(find.textContaining('Soprano, alto'), findsOneWidget, reason: 'the description');
    final item = tester.widget<PopupMenuItem<String>>(find.byKey(const Key('build-2026-10-24_audition sax v1 (56f7266)')));
    expect(item.enabled, isFalse, reason: 'cannot be chosen: it does not load');
    expect(find.text('Install a build or an engine…'), findsOneWidget);
    expect(find.text('Open the firmware folder'), findsOneWidget);
    await tester.tap(find.byKey(const Key('build-2026-10-23_this run')));
    await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
    expect(ctl.firmwarePath, File('${real.path}$sep${virtualLibName()}').absolute.path);
    expect(tester.widget<Btn>(find.byKey(const Key('mode-virtual'))).label, 'Virtual · 2026-10-23_this run ▾');
    await finish(tester, ctl);
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });
}
