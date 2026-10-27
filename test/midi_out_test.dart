// MIDI out in Setup, as the board has it (StcY), on Virtual (the real firmware): the mode from the
// board's settings keys (StcX's MIDI switches) with the one the board plays selected, the channels
// and the bend range, the volume, sustain and rate; a mode switched over USB (StcK) and read back.
// And the MIDI monitor's messages in words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/theme.dart';

import 'support/virtual.dart';

void main() {
  testWidgets('MIDI out: the board\'s mode and channels, switched with its keys and read back', skip: virtualSkip != null, (tester) async {
    final ctl = await bootApp(tester);
    await playVirtual(tester, ctl);
    ctl.setTab(AppTab.setup);
    await settle(tester, ms: 400);
    expect(find.text('MIDI OUT'), findsOneWidget);
    Btn seg(String m) => tester.widget<Btn>(find.byKey(Key('midi-mode-$m')));
    expect(seg('0').pressed, isTrue, reason: 'StcY midi=mpe');
    expect(seg('2').pressed, isFalse);
    // a firmware without StcT: the values as text, the dials set on the instrument
    await waitFor(tester, () => ctl.dials != null, ms: 2000);
    ctl.dials = null;
    ctl.notifyListeners();
    await settle(tester, ms: 100);
    expect(find.text('MPE · 10 voices from channel 2 · pitch bend 48 semitones'), findsOneWidget);
    expect(find.text('volume 90 · sustain 0.19 · a message every 1 ms'), findsOneWidget);
    // Poly: the board's settings key 2, pressed over USB; what the board then reports
    await tester.ensureVisible(find.byKey(const Key('midi-mode-2')));
    await tester.tap(find.byKey(const Key('midi-mode-2')));
    await waitFor(tester, () => ctl.boardState?.midi == 'poly', ms: 2000);
    await settle(tester, ms: 200);
    expect(seg('2').pressed, isTrue);
    expect(find.text('Poly · channel 1'), findsOneWidget, reason: 'poly plays on channel 1 (the firmware sets it)');
    await finish(tester, ctl);
  });

  testWidgets('the dials as sliders in the board\'s ranges: a drag sends the value, the board\'s answer shows', skip: virtualSkip != null, (tester) async {
    final ctl = await bootApp(tester);
    await playVirtual(tester, ctl);
    await waitFor(tester, () => ctl.dials != null, ms: 2000);
    expect(ctl.dials!.map((d) => d.name), ['ch', 'voices', 'bend', 'vol', 'sustain', 'rate', 'fine'], reason: 'as the board lists them');
    ctl.setTab(AppTab.setup);
    await settle(tester, ms: 400);
    String value(String n) => tester.widget<Text>(find.byKey(Key('dial-$n-value'))).data!;
    expect(value('vol'), '90');
    expect(value('bend'), '48 st');
    expect(value('sustain'), '0.188');
    // a value set: the board's answer, and StcY's afterwards
    expect(await run(tester, ctl.setDial(ctl.dials!.firstWhere((d) => d.name == 'vol'), 130)), 127, reason: 'clamped by the board');
    await settle(tester, ms: 200);
    expect(value('vol'), '127');
    expect(await run(tester, ctl.setDial(ctl.dials!.firstWhere((d) => d.name == 'bend'), 30)), 24);
    await settle(tester, ms: 200);
    expect(value('bend'), '24 st');
    // a drag on the slider: the value at its end goes to the board
    await tester.ensureVisible(find.byKey(const Key('dial-rate')));
    await settle(tester, ms: 100);
    await tester.drag(find.byKey(const Key('dial-rate')), const Offset(400, 0));
    await waitFor(tester, () => ctl.boardState?.rate == 15, ms: 2000);
    await settle(tester, ms: 100);
    expect(value('rate'), '15 ms');
    await finish(tester, ctl);
  });

  test('the MIDI monitor\'s messages in words', () {
    expect(AppController.midiMonitorLine(1, [0x9, 60, 100], 3), 'MIDI in · ch 1 · note on 60 velocity 100');
    expect(AppController.midiMonitorLine(2, [0xB, 74, 70], 3), 'MIDI in · ch 2 · control 74 = 70');
    expect(AppController.midiMonitorLine(1, [0xE, 0x00, 0x48], 3), 'MIDI in · ch 1 · pitch bend 1024');
    expect(AppController.midiMonitorLine(1, [0xD, 80, 0], 3), 'MIDI in · ch 1 · channel pressure 80');
  });
}
