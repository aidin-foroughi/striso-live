// Widget tests of the main panels against the demo board (no USB, no window).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/app_log.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/ui/knobs.dart';

Future<AppController> boot(WidgetTester tester, {AppOptions options = const AppOptions(noUsb: true), Size size = const Size(1600, 1500)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ctl = AppController(options: options, store: Store.memory(), backupDir: '${Directory.systemTemp.path}/striso_live_test_backups');
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

Future<void> startDemo(WidgetTester tester, AppController ctl) async {
  await tester.tap(find.byKey(const Key('btn-demo')));
  // the demo answers over timers: connect, version, voices, the four lists
  for (var i = 0; i < 60 && (ctl.listsLoading || ctl.dot != Dot.demo || ctl.params[3]!.params.isEmpty); i++) {
    await runFor(tester, 50);
  }
  expect(ctl.connected, isTrue);
  expect(ctl.listsLoading, isFalse);
}

/// Awaits [f] while fake time moves on (the demo board answers over fake timers).
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
  await settle(tester, 7000); // toasts, the load poll
  await tester.pumpWidget(const SizedBox());
  ctl.dispose();
}

void main() {
  testWidgets('boots to the invite card, then the demo fills voices, now playing and the racks', (tester) async {
    final ctl = await boot(tester);
    expect(find.text('Plug in your Striso'), findsOneWidget);
    expect(find.byKey(const Key('btn-connect-2')), findsOneWidget);
    expect(find.text('No voice'), findsOneWidget);
    await startDemo(tester, ctl);
    await settle(tester);
    expect(find.text('Plug in your Striso'), findsNothing);
    expect(find.byKey(const Key('demo-chip')), findsOneWidget);
    expect(find.byKey(const Key('now-preset')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('now-preset'))).data, 'classic');
    // the voice browser: the engine row and the current engine's presets
    expect(find.byKey(const Key('engine-modal')), findsOneWidget);
    expect(find.text('pad'), findsOneWidget);
    // the Play tab's main knobs
    expect(find.byType(Knob), findsWidgets);
    // the Sound tab's racks: a knob or switch per parameter
    await tester.tap(find.byKey(const Key('tab-sound')));
    await settle(tester, 300);
    expect(
      find.byType(Knob).evaluate().length + find.byType(ToggleCtl).evaluate().length,
      ctl.params[0]!.params.length + ctl.params[1]!.params.length,
    );
    expect(ctl.params[0]!.params.length, 55);
    await finish(tester, ctl);
  });

  testWidgets('switching voice from a tile reads the new parameters; undo and redo', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.tap(find.byKey(const Key('engine-modal')));
    for (var i = 0; i < 20 && !ctl.voiceName.startsWith('modal'); i++) {
      await runFor(tester, 50);
    }
    expect(ctl.voiceName, startsWith('modal'));
    await tester.tap(find.text('wine glass'));
    for (var i = 0; i < 20 && ctl.voiceName != 'modal:wine glass'; i++) {
      await runFor(tester, 50);
    }
    expect(ctl.voiceName, 'modal:wine glass');
    expect(tester.widget<Text>(find.byKey(const Key('now-preset'))).data, 'wine glass');
    // a change through the controller, as a knob drag does, then undo/redo from the buttons
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    final before = p.value;
    await tester.tap(find.byKey(const Key('tab-sound')));
    await settle(tester, 300);
    ctl.onEdit(0, p, p.min + (p.max - p.min) * 0.8, 'begin', 'Change ${p.name}');
    ctl.onEdit(0, p, p.value, 'end');
    await settle(tester, 100);
    expect(p.value, isNot(before));
    await tester.ensureVisible(find.byKey(const Key('btn-undo')));
    await tester.tap(find.byKey(const Key('btn-undo')));
    await settle(tester, 100);
    expect(p.value, before);
    await tester.tap(find.byKey(const Key('btn-redo')));
    await settle(tester, 100);
    expect(p.value, isNot(before));
    await finish(tester, ctl);
  });

  testWidgets('settings overlay: the panel, a voice key click switches voice', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, 300);
    expect(find.byKey(const Key('settings-panel')), findsNothing);
    await tester.tap(find.byKey(const Key('btn-settings-overlay')));
    await settle(tester, 200);
    expect(find.byKey(const Key('settings-panel')), findsOneWidget);
    expect(find.text('SETTINGS MODE'), findsOneWidget);
    // the modal voice key (button 22) picks the modal engine, like the Striso
    expect(ctl.settingsClick(22), isTrue);
    await settle(tester, 100);
    expect(find.textContaining('Voice: modal'), findsOneWidget);
    for (var i = 0; i < 20 && !ctl.voiceName.startsWith('modal'); i++) {
      await runFor(tester, 50);
    }
    expect(ctl.voiceName, startsWith('modal'));
    await tester.tap(find.byKey(const Key('mode-sensitivity')));
    await settle(tester, 200);
    expect(find.byKey(const Key('settings-panel')), findsNothing);
    await finish(tester, ctl);
  });

  testWidgets('touch panel and key equalizer: sliders, selection, live peaks, Suggest', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, 300);
    expect(find.text('Threshold'), findsOneWidget);
    expect(ctl.params[2]!.params.length, 5);
    expect(ctl.params[3]!.params.length, 61);
    await tester.ensureVisible(find.byKey(const Key('eq-on')));
    await tester.tap(find.byKey(const Key('eq-on')));
    await settle(tester, 100);
    expect(ctl.eqOn, isTrue);
    // press three keys on the demo board with the same force: their peaks differ by key gain
    final board = ctl.demoBoard!;
    board.autoplay = false;
    for (final id in [25, 27, 29, 31]) {
      board.press(id, pres: 0.3, strike: 0);
      await runFor(tester, 60);
      board.release(id);
      await runFor(tester, 60);
    }
    expect(ctl.measuredKeys().length, greaterThanOrEqualTo(3));
    expect(ctl.eqSelected, 31, reason: 'follows the last pressed key');
    await settle(tester, 200);
    expect(tester.widget<Text>(find.byKey(const Key('eq-keyname'))).data, noteName(31).full);
    await tester.ensureVisible(find.byKey(const Key('eq-suggest')));
    await tester.tap(find.byKey(const Key('eq-suggest')));
    await settle(tester, 300);
    final apply = find.byKey(const Key('dlg-suggest-apply'));
    expect(apply, findsOneWidget, reason: 'the demo keys differ in gain, so Suggest has changes');
    {
      await tester.tap(apply);
      for (var i = 0; i < 10; i++) {
        await runFor(tester, 30);
      }
      expect(ctl.history.canUndo, isTrue);
      // the board took the new factors
      for (final id in [25, 27, 29, 31]) {
        final n = keyNumberOf[id]!;
        expect(board.keyFactors[n], closeTo(ctl.keyParam(id)!.value, 1e-6));
      }
    }
    await finish(tester, ctl);
  });

  testWidgets('console drawer: diagnostics, a console command and its reply, blocked commands', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.ensureVisible(find.byKey(const Key('console-toggle')));
    await tester.tap(find.byKey(const Key('console-toggle')));
    await settle(tester, 200);
    expect(find.byKey(const Key('diag')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('console-cmd')), 'v');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 10; i++) {
      await runFor(tester, 50);
    }
    final log = appLog.lines.map((l) => l.text).toList();
    expect(log, contains('> Stcv'));
    expect(log.any((l) => l.contains('modal:wine glass')), isTrue);
    await tester.enterText(find.byKey(const Key('console-cmd')), 'B');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, 100);
    expect(appLog.lines.last.text, contains('is blocked here'));
    await finish(tester, ctl);
  });

  testWidgets('save to Striso (fake drive): confirm, backup, reconnect and read back', (tester) async {
    final ctl = await boot(tester, options: const AppOptions(noUsb: true, fakeSave: 'ok'));
    await startDemo(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, 300);
    final p = ctl.findParam(2, 'pressure')!;
    ctl.onEdit(2, p, 1.5, 'begin', 'Touch pressure');
    ctl.onEdit(2, p, 1.5, 'end');
    await tester.ensureVisible(find.byKey(const Key('btn-save-board')));
    await tester.tap(find.byKey(const Key('btn-save-board')));
    await settle(tester, 300);
    await tester.tap(find.byKey(const Key('dlg-save-go')));
    for (var i = 0; i < 60 && (ctl.saving || ctl.saveStatus.cls.isEmpty); i++) {
      await runFor(tester, 50);
    }
    expect(ctl.saveStatus.cls, 'ok', reason: ctl.saveStatus.text);
    expect(ctl.saveStatus.text, startsWith('Saved and read back'));
    expect(ctl.findParam(2, 'pressure')!.value, closeTo(1.5, 1e-6));
    await finish(tester, ctl);
  });

  testWidgets('narrow window: the panels stack without overflow', (tester) async {
    final ctl = await boot(tester, size: const Size(740, 2400));
    await startDemo(tester, ctl);
    await settle(tester, 300);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('engine-va')), findsOneWidget);
    await finish(tester, ctl);
  });
  testWidgets('stage mode (F, Esc), the shortcut overlay (?) and A/B', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await settle(tester, 500);
    expect(find.byKey(const Key('stage')), findsOneWidget);
    expect(find.byKey(const Key('stage-chord')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 500);
    expect(find.byKey(const Key('stage')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester, 200);
    expect(find.byKey(const Key('shortcuts')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 200);
    expect(find.byKey(const Key('shortcuts')), findsNothing);
    // A/B: hold B for the preset as loaded, release for the edits
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    ctl.onEdit(0, p, p.min + (p.max - p.min) * 0.9, 'begin', 'x');
    ctl.onEdit(0, p, p.value, 'end');
    final edited = p.value;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await settle(tester, 100);
    expect(ctl.abOn, isTrue);
    expect(p.value, p.loadValue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await settle(tester, 100);
    expect(ctl.abOn, isFalse);
    expect(p.value, edited);
    expect(ctl.history.canRedo, isFalse, reason: 'A/B is not an edit');
    await finish(tester, ctl);
  });

  testWidgets('scale picker: grouped, search, formula; Barry Harris shows its two chords', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await tester.tap(find.byKey(const Key('key-scale')));
    await settle(tester, 200);
    expect(find.text('COMMON'), findsOneWidget);
    expect(find.text('MODES OF MAJOR'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'phrygian dom');
    await settle(tester, 200);
    expect(find.text('1 ♭2 3 4 5 ♭6 ♭7'), findsWidgets); // Phrygian dominant and Flamenco
    await tester.tap(find.byKey(const Key('scale-phrygdom')));
    await settle(tester, 200);
    expect(ctl.keyScale, 'phrygdom');
    ctl.setKey(root: 0, scale: 'bh6dim');
    await settle(tester, 200);
    expect(find.byKey(const Key('bh-text')), findsOneWidget);
    expect(find.textContaining('C6 (C E G A) + B°7'), findsOneWidget);
    await finish(tester, ctl);
  });
}
