// Widget tests of the main panels on Virtual, the firmware's own code (striso_virtual; no USB, no
// window, no audio): what they show is what the firmware lists and reports.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/app_log.dart';
import 'package:striso_live/src/ui/knobs.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

void main() {
  final skip = virtualSkip != null;

  testWidgets('boots to the invite card, then Virtual fills voices, now playing and the racks', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    expect(find.text('Plug in your Striso'), findsOneWidget);
    // the Striso connects by itself: the start screen offers Virtual only
    expect(find.byKey(const Key('fix-playVirtual')), findsOneWidget);
    expect(find.byKey(const Key('fix-connectStriso')), findsNothing);
    expect(find.byKey(const Key('btn-connect')), findsNothing, reason: 'nothing to end: no button');
    expect(find.text('No voice'), findsOneWidget);
    await tapPlayVirtual(tester, ctl);
    await settle(tester, ms: 600);
    expect(find.text('Plug in your Striso'), findsNothing);
    expect(find.byKey(const Key('board-tag')), findsOneWidget);
    // now playing: the voice the firmware starts on (StcV)
    final current = ctl.voices.firstWhere((v) => v.index == ctl.virtual.instrument!.board.state.voice);
    expect(ctl.voiceName, current.name);
    expect(tester.widget<Text>(find.byKey(const Key('now-preset'))).data, current.preset);
    // the voice browser: the engine row and the current engine's presets, as the firmware lists them
    for (final e in ctl.voices.map((v) => v.engine).toSet()) {
      expect(find.byKey(Key('engine-$e')), findsOneWidget, reason: e);
    }
    final sibling = ctl.voices.firstWhere((v) => v.engine == current.engine && v.index != current.index);
    expect(find.text(sibling.preset!), findsOneWidget);
    // the Play tab's main knobs
    expect(find.byType(Knob), findsWidgets);
    // the Sound tab's racks: a knob or switch per parameter the board lists
    await tester.tap(find.byKey(const Key('tab-sound')));
    await settle(tester, ms: 300);
    final p0 = (await run(tester, ctl.client!.getParams(0)))!, p1 = (await run(tester, ctl.client!.getParams(1)))!;
    expect(ctl.params[0]!.params.map((p) => p.name), p0.params.map((p) => p.name));
    expect(ctl.params[1]!.params.map((p) => p.name), p1.params.map((p) => p.name));
    expect(find.byType(Knob).evaluate().length + find.byType(ToggleCtl).evaluate().length, p0.params.length + p1.params.length);
    await finish(tester, ctl);
  });

  testWidgets('switching voice from a tile reads the new parameters; undo and redo', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.tap(find.byKey(const Key('engine-modal')));
    await waitFor(tester, () => ctl.voiceName.startsWith('modal:'));
    await settle(tester, ms: 200);
    await tester.tap(find.text('wine glass'));
    await waitFor(tester, () => ctl.voiceName == 'modal:wine glass' && ctl.params[0]!.params.isNotEmpty);
    expect(ctl.voices[ctl.virtual.instrument!.board.state.voice].name, 'modal:wine glass');
    await settle(tester, ms: 200);
    expect(tester.widget<Text>(find.byKey(const Key('now-preset'))).data, 'wine glass');
    expect(ctl.params[0]!.params.map((p) => p.name), (await run(tester, ctl.client!.getParams(0)))!.params.map((p) => p.name));
    // a change through the controller, as a knob drag does, then undo/redo from the buttons
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    final before = p.value;
    await tester.tap(find.byKey(const Key('tab-sound')));
    await settle(tester, ms: 300);
    ctl.onEdit(0, p, p.min + (p.max - p.min) * 0.8, 'begin', 'Change ${p.name}');
    ctl.onEdit(0, p, p.value, 'end');
    await settle(tester, ms: 100);
    expect(p.value, isNot(before));
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, p.value, reason: 'the board has it');
    await tester.ensureVisible(find.byKey(const Key('btn-undo')));
    await tester.tap(find.byKey(const Key('btn-undo')));
    await settle(tester, ms: 100);
    expect(p.value, before);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, before);
    await tester.tap(find.byKey(const Key('btn-redo')));
    await settle(tester, ms: 100);
    expect(p.value, isNot(before));
    await finish(tester, ctl);
  });

  testWidgets('settings overlay: the panel, a voice key click switches voice', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, ms: 300);
    expect(find.byKey(const Key('settings-panel')), findsNothing);
    await tester.tap(find.byKey(const Key('btn-settings-overlay')));
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('settings-panel')), findsOneWidget);
    expect(find.text('SETTINGS MODE'), findsOneWidget);
    // the modal voice key, where the firmware's layout (StcX) has it, picks the modal engine
    final modalKey = ctl.settingsLayout.keys.entries.firstWhere((e) => e.value.engine == 'modal').key;
    expect(ctl.settingsClick(modalKey), isTrue);
    await settle(tester, ms: 100);
    expect(find.textContaining('Voice: modal'), findsOneWidget);
    await waitFor(tester, () => ctl.voiceName.startsWith('modal:'));
    expect(ctl.voices[ctl.virtual.instrument!.board.state.voice].engine, 'modal');
    await tester.tap(find.byKey(const Key('mode-sensitivity')));
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('settings-panel')), findsNothing);
    await finish(tester, ctl);
  });

  testWidgets('touch panel and key equalizer: sliders, selection, live peaks, Suggest', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, ms: 300);
    expect(find.text('Threshold'), findsOneWidget);
    expect(ctl.params[2]!.params.length, (await run(tester, ctl.client!.getParams(2)))!.params.length);
    expect(ctl.params[3]!.params.length, (await run(tester, ctl.client!.getParams(3)))!.params.length);
    await tester.ensureVisible(find.byKey(const Key('eq-on')));
    await tester.tap(find.byKey(const Key('eq-on')));
    await settle(tester, ms: 100);
    expect(ctl.eqOn, isTrue);
    // four keys pressed unevenly on the instrument (as keys that differ in feel): the peaks are
    // the firmware's, and differ
    const keys = [25, 27, 29, 31];
    const force = [0.22, 0.3, 0.38, 0.3];
    for (var i = 0; i < keys.length; i++) {
      press(ctl, [keys[i]], pres: force[i]);
      await settle(tester, ms: 120);
      release(ctl, [keys[i]]);
      await settle(tester, ms: 120);
    }
    await waitFor(tester, () => ctl.measuredKeys().length >= 4);
    expect(ctl.eqSelected, 31, reason: 'follows the last pressed key');
    await settle(tester, ms: 200);
    expect(tester.widget<Text>(find.byKey(const Key('eq-keyname'))).data, ctl.keyLayout!.noteName(31).full);
    await tester.ensureVisible(find.byKey(const Key('eq-suggest')));
    await tester.tap(find.byKey(const Key('eq-suggest')));
    await settle(tester, ms: 300);
    final apply = find.byKey(const Key('dlg-suggest-apply'));
    expect(apply, findsOneWidget, reason: 'the keys were pressed unevenly, so Suggest has changes');
    await tester.tap(apply);
    await settle(tester, ms: 300);
    expect(ctl.history.canUndo, isTrue);
    // the board took the new factors
    final onBoard = (await run(tester, ctl.client!.getParams(3)))!.params;
    final layout = ctl.keyLayout!;
    for (final id in keys) {
      final n = layout.keyNumberOf(id)!;
      expect(onBoard[n].value, closeTo(ctl.keyParam(id)!.value, 1e-6), reason: 'key $id');
    }
    expect(onBoard[layout.keyNumberOf(25)!].value, greaterThan(onBoard[layout.keyNumberOf(29)!].value), reason: 'the softer key gets more');
    await finish(tester, ctl);
  });

  testWidgets('console drawer: diagnostics, a console command and its reply, blocked commands', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.ensureVisible(find.byKey(const Key('console-toggle')));
    await tester.tap(find.byKey(const Key('console-toggle')));
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('diag')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('console-cmd')), 'v');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // the firmware's voice list, the current entry starred
    final current = ctl.voices.firstWhere((v) => v.name == ctl.voiceName);
    bool logged(String t) => appLog.lines.any((l) => l.text.trim() == t);
    await waitFor(tester, () => logged('* ${current.index} ${current.name}'));
    expect(logged('> Stcv'), isTrue);
    expect(logged('${ctl.voices.last.index} ${ctl.voices.last.name}'), isTrue);
    await tester.enterText(find.byKey(const Key('console-cmd')), 'B');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, ms: 100);
    expect(appLog.lines.last.text, contains('is blocked here'));
    expect(ctl.virtual.instrument!.board.inBootloader, isFalse);
    await finish(tester, ctl);
  });

  testWidgets('save to Striso: confirm, the board\'s drive, restart and read back', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.tap(find.byKey(const Key('tab-setup')));
    await settle(tester, ms: 300);
    final p = ctl.findParam(2, 'pressure')!;
    ctl.onEdit(2, p, 1.5, 'begin', 'Touch pressure');
    ctl.onEdit(2, p, 1.5, 'end');
    await tester.ensureVisible(find.byKey(const Key('btn-save-board')));
    await tester.tap(find.byKey(const Key('btn-save-board')));
    await settle(tester, ms: 300);
    await tester.tap(find.byKey(const Key('dlg-save-go')));
    await waitFor(tester, () => !ctl.saving && ctl.saveStatus.cls.isNotEmpty, ms: 30000);
    expect(ctl.saveStatus.cls, 'ok', reason: ctl.saveStatus.text);
    expect(ctl.saveStatus.text, startsWith('Saved and read back'));
    await waitFor(tester, () => ctl.client != null && !ctl.listsLoading);
    expect(ctl.findParam(2, 'pressure')!.value, closeTo(1.5, 1e-6));
    expect((await run(tester, ctl.client!.getParams(2)))!.params.firstWhere((x) => x.name == 'pressure').value, closeTo(1.5, 1e-6));
    expect(ctl.virtual.instrument!.board.state.resets, greaterThan(0), reason: 'the board restarted on its saved flash');
    await finish(tester, ctl);
  });

  testWidgets('narrow window: the panels stack without overflow', skip: skip, (tester) async {
    final ctl = await bootApp(tester, size: const Size(740, 2400));
    await tapPlayVirtual(tester, ctl);
    await settle(tester, ms: 300);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('engine-va')), findsOneWidget);
    await finish(tester, ctl);
  });

  testWidgets('stage mode (F, Esc), the shortcut overlay (?) and A/B', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await settle(tester, ms: 500);
    expect(find.byKey(const Key('stage')), findsOneWidget);
    expect(find.byKey(const Key('stage-chord')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, ms: 500);
    expect(find.byKey(const Key('stage')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('shortcuts')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('shortcuts')), findsNothing);
    // A/B: hold B for the preset as loaded, release for the edits; the board plays each
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    ctl.onEdit(0, p, p.min + (p.max - p.min) * 0.9, 'begin', 'x');
    ctl.onEdit(0, p, p.value, 'end');
    final edited = p.value;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await settle(tester, ms: 100);
    expect(ctl.abOn, isTrue);
    expect(p.value, p.loadValue);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, p.loadValue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await settle(tester, ms: 100);
    expect(ctl.abOn, isFalse);
    expect(p.value, edited);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, edited);
    expect(ctl.history.canRedo, isFalse, reason: 'A/B is not an edit');
    await finish(tester, ctl);
  });

  testWidgets('scale picker: grouped, search, formula; Barry Harris shows its two chords', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await tester.tap(find.byKey(const Key('key-scale')));
    await settle(tester, ms: 200);
    expect(find.text('COMMON'), findsOneWidget);
    expect(find.text('MODES OF MAJOR'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'phrygian dom');
    await settle(tester, ms: 200);
    expect(find.text('1 ♭2 3 4 5 ♭6 ♭7'), findsWidgets); // Phrygian dominant and Flamenco
    await tester.tap(find.byKey(const Key('scale-phrygdom')));
    await settle(tester, ms: 200);
    expect(ctl.keyScale, 'phrygdom');
    ctl.setKey(root: 0, scale: 'bh6dim');
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('bh-text')), findsOneWidget);
    expect(find.textContaining('C6 (C E G A) + B°7'), findsOneWidget);
    await finish(tester, ctl);
  });
}
