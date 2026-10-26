// MIDI out in Setup, as the board has it (StcY), on the Dart mock: the mode from the board's
// settings keys (StcX's MIDI switches) with the one the board plays selected, the channels and the
// bend range, the volume, sustain and rate; a mode switched over USB (StcK) and read back. And the
// MIDI monitor's messages in words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/theme.dart';

import 'flows_test.dart' show boot, finish, pumpUntil, settle, untilLive;

void main() {
  testWidgets('MIDI out: the board\'s mode and channels, switched with its keys and read back', (tester) async {
    final ctl = await boot(tester, AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store.memory()));
    await pumpUntil(tester, ctl.playVirtual());
    await untilLive(tester, ctl);
    ctl.setTab(AppTab.setup);
    await settle(tester, 400);
    expect(find.text('MIDI OUT'), findsOneWidget);
    Btn seg(String m) => tester.widget<Btn>(find.byKey(Key('midi-mode-$m')));
    expect(seg('mpe').pressed, isTrue, reason: 'StcY midi=mpe');
    expect(seg('poly').pressed, isFalse);
    expect(find.text('MPE · 10 voices from channel 2 · pitch bend 48 semitones'), findsOneWidget);
    expect(find.text('volume 90 · sustain 0.19 · a message every 1 ms'), findsOneWidget);
    // Poly: the board's settings key 2, pressed over USB; what the board then reports
    await tester.ensureVisible(find.byKey(const Key('midi-mode-poly')));
    await tester.tap(find.byKey(const Key('midi-mode-poly')));
    for (var i = 0; i < 40 && ctl.boardState?.midi != 'poly'; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 50);
    }
    expect(ctl.boardState?.midi, 'poly');
    await settle(tester, 200);
    expect(seg('poly').pressed, isTrue);
    expect(find.text('Poly · channel 1'), findsOneWidget);
    await finish(tester, ctl);
  });

  test('the MIDI monitor\'s messages in words', () {
    expect(AppController.midiMonitorLine(1, [0x9, 60, 100], 3), 'MIDI in · ch 1 · note on 60 velocity 100');
    expect(AppController.midiMonitorLine(2, [0xB, 74, 70], 3), 'MIDI in · ch 2 · control 74 = 70');
    expect(AppController.midiMonitorLine(1, [0xE, 0x00, 0x48], 3), 'MIDI in · ch 1 · pitch bend 1024');
    expect(AppController.midiMonitorLine(1, [0xD, 80, 0], 3), 'MIDI in · ch 1 · channel pressure 80');
  });
}
