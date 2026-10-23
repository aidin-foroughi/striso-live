// The tuning-aware labels, the colour modes and the settings keys over USB, against the demo
// board (no USB, no window). Helpers come from widget_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/ui/accidentals.dart';

import 'widget_test.dart' show boot, finish, pumpUntil, runFor, settle, startDemo;

/// A demo board whose firmware predates N and K: both commands are swallowed.
class _OldBoard extends MockBoard {
  _OldBoard() : super(autoplay: false, motionEnabled: false, idleFrames: 0);
  @override
  void receive(List<int> bytes) {
    if (bytes.length >= 4 && bytes[0] == 0x53 && bytes[1] == 0x74 && bytes[2] == 0x63 && (bytes[3] == 0x4e || bytes[3] == 0x4b)) return;
    super.receive(bytes);
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() done, {int tries = 60}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await runFor(tester, 50);
  }
  expect(done(), isTrue, reason: 'did not happen');
}

void main() {
  testWidgets('the demo reports its tuning; a change suggests pitch labels once; the labels follow', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await waitFor(tester, () => ctl.tuningSupported == true);
    expect(ctl.tuning!.isPlain12, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('tuning-chip'))).data, '12-TET');
    expect(find.byKey(const Key('toast-Pitch labels')), findsNothing);
    // the instrument switches to 31-TET (settings + key on the board): the app re-reads after the button
    ctl.demoBoard!.loadTuning(1);
    ctl.live.apply(Src.control, Idc.alt, Int32List.fromList([1]), 1, 0);
    ctl.live.apply(Src.control, Idc.alt, Int32List.fromList([0]), 1, 0);
    await waitFor(tester, () => ctl.tuning?.index == 1);
    await settle(tester, 300);
    expect(tester.widget<Text>(find.byKey(const Key('tuning-chip'))).data, '31-TET');
    expect(find.byKey(const Key('toast-Pitch labels')), findsOneWidget);
    expect(find.byKey(const Key('tuning-note')), findsOneWidget); // chords by spelling
    await tester.tap(find.byKey(const Key('toast-Pitch labels')));
    await settle(tester, 300);
    expect(ctl.names, Names.pitch);
    // 31-TET C♯4 (button 30): a sharp whose second stroke is 68% tall, 16 cents under 12-TET
    final cs = ctl.qtLabel(30);
    expect(cs.letter, 'C');
    expect(cs.qt, closeTo(1.677, 0.001));
    expect(cs.centsFrom12, closeTo(-16.1, 0.1));
    expect(qtAccidentalWidth(20, cs.qt), greaterThan(0));
    // the hover readout tells the cents and the nearest quarter tone
    ctl.hover = 30;
    ctl.stats.ping();
    await settle(tester, 200);
    final readout = tester.widget<Text>(find.byKey(const Key('hover-readout'))).data!;
    expect(readout, contains('C♯4'));
    expect(readout, contains('−16.1 ¢ vs 12-TET'));
    expect(readout, contains('nearest quarter tone C sharp −16 ¢'));
    ctl.hover = -1;
    // the key root as reference makes the root exact (C is +6.45 cents absolute in 31-TET on D)
    final cKey = keyIds.firstWhere((id) => c0[id] == 1 && c1[id] == -2);
    expect(ctl.qtLabel(cKey).centsFrom12, closeTo(6.45, 0.01));
    ctl.setPitchRef(PitchRef.root);
    expect(ctl.qtLabel(cKey).centsFrom12, closeTo(0, 1e-6));
    expect(ctl.qtLabel(30).centsFrom12, closeTo(-22.6, 0.1)); // C♯ against the tuning's own C
    ctl.setPitchRef(PitchRef.absolute);
    // the suggestion came once: a second change only reports the name
    ctl.demoTuning(8);
    await waitFor(tester, () => ctl.tuning?.index == 8);
    await settle(tester, 300);
    expect(find.byKey(const Key('toast-Pitch labels')), findsNothing);
    expect(find.textContaining('Tuning: Just 7-limit'), findsOneWidget);
    expect(ctl.tuningName, 'Just 7-limit');
    // cents mode, and the slow poll picks up a change made behind the app's back
    ctl.setNames(Names.cents);
    ctl.demoBoard!.fineTune(-31.77);
    await waitFor(tester, () => (ctl.tuning?.offsetCents ?? 0) < -30);
    await settle(tester, 300);
    expect(tester.widget<Text>(find.byKey(const Key('reference-chip'))).data, 'A = 432.0 Hz (−32 ¢)');
    // labels are notated relative to that reference: D4 reads exact
    expect(ctl.qtLabel(25).qt, closeTo(0.207, 0.001)); // just D is +10.4 cents, fine tune taken out
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('old firmware: no N reply means 12-TET from the layout, no K reply a one-time hint', (tester) async {
    final ctl = await boot(tester);
    final board = _OldBoard();
    await pumpUntil(tester, ctl.startSession(MockTransport(board: board), ConnMode.demo));
    for (var i = 0; i < 60 && (ctl.listsLoading || ctl.tuningSupported == null); i++) {
      await runFor(tester, 50);
    }
    expect(ctl.tuningSupported, isFalse);
    expect(ctl.tuning, isNull);
    expect(ctl.tuningName, '12-TET');
    expect(ctl.keyPitch(30), 61); // C♯4 from the layout
    ctl.setNames(Names.pitch);
    await settle(tester, 300);
    expect(ctl.qtLabel(30).qt, 2);
    expect(ctl.qtLabel(30).centsFrom12, 0);
    // a tuning key in the settings overlay: no reply within 300 ms, one hint, nothing changes
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    await settle(tester, 300);
    expect(await pumpUntil(tester, ctl.pressSettingsKey(36)), isFalse);
    await settle(tester, 200);
    expect(find.textContaining("can't switch tunings from the app yet"), findsOneWidget);
    expect(await pumpUntil(tester, ctl.pressSettingsKey(38)), isFalse);
    await settle(tester, 200);
    expect(find.textContaining("can't switch tunings from the app yet"), findsOneWidget);
    expect(board.tuning, 0);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('settings overlay: switch keys press the board (K), dials do not; presets re-read settings', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await waitFor(tester, () => ctl.tuningSupported == true);
    final board = ctl.demoBoard!;
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    await settle(tester, 300);
    // a tuning key: the board switches, the tuning is read again and named in the overlay
    expect(ctl.settingsClick(36), isTrue);
    await waitFor(tester, () => ctl.tuning?.index == 1);
    expect(board.tuning, 1);
    expect(ctl.tuningShort, '31TET');
    expect(ctl.settingsSelected, 36);
    // the led pulse was asked for
    expect(clockMs() - ctl.ledPulseT, lessThan(60000));
    // a dial key only selects
    final pressure = board.touch[0];
    expect(ctl.settingsClick(19), isTrue);
    await settle(tester, 500);
    expect(board.touch[0], pressure);
    expect(ctl.settingsSelected, 19);
    // a settings preset: the touch settings are read back, with a toast
    final p = ctl.findParam(2, 'pressure')!;
    ctl.onEdit(2, p, 2.5, 'begin');
    ctl.onEdit(2, p, 2.5, 'end');
    await runFor(tester, 100); // the write reaches the board before the preset key
    expect(board.touch[0], 2.5);
    expect(ctl.settingsClick(37), isTrue);
    await waitFor(tester, () => board.settingsPreset == 2);
    await waitFor(tester, () => ctl.findParam(2, 'pressure')!.value == 1.0);
    await settle(tester, 300);
    expect(find.textContaining('Loaded settings preset 2'), findsOneWidget);
    // MIDI mode and panic answer ok; the refused keys are not switchable at all
    expect(await pumpUntil(tester, ctl.pressSettingsKey(4)), isTrue);
    expect(board.midiMode, 'mono');
    expect(await pumpUntil(tester, ctl.pressSettingsKey(63)), isTrue);
    expect(await pumpUntil(tester, ctl.pressSettingsKey(67)), isFalse);
    expect(await pumpUntil(tester, ctl.pressSettingsKey(17)), isFalse);
    // back to 12-TET
    expect(ctl.settingsClick(34), isTrue);
    await waitFor(tester, () => ctl.tuning?.index == 0);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('colour modes: the legend follows the mode, chord tones while a chord is held', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    ctl.setKey(root: 0, scale: 'major');
    expect(find.byKey(const Key('colour-legend')), findsNothing);
    ctl.setColour(KeyColour.degree);
    await settle(tester, 300);
    expect(find.byKey(const Key('colour-legend')), findsOneWidget);
    for (final d in ['1', '2', '3', '4', '5', '6', '7']) {
      expect(find.descendant(of: find.byKey(const Key('colour-legend')), matching: find.text(d)), findsOneWidget);
    }
    ctl.setColour(KeyColour.function);
    await settle(tester, 300);
    for (final f in ['T', 'S', 'D']) {
      expect(find.descendant(of: find.byKey(const Key('colour-legend')), matching: find.text(f)), findsOneWidget);
    }
    ctl.setColour(KeyColour.chord);
    await settle(tester, 300);
    // nothing held: the degree legend
    expect(find.descendant(of: find.byKey(const Key('colour-legend')), matching: find.text('7')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('colour-legend')), matching: find.text('R')), findsNothing);
    // G7 held: root, third, fifth, seventh
    final b = ctl.demoBoard!..autoplay = false;
    await runFor(tester, 100);
    for (final id in [41, 45, 25, 22]) {
      b.press(id, pres: 0.5, strike: 0.3);
    }
    await waitFor(tester, () => ctl.harmony.shown?.name == 'G7');
    await settle(tester, 300);
    for (final r in ['R', '3', '5', '7', '+']) {
      expect(find.descendant(of: find.byKey(const Key('colour-legend')), matching: find.text(r)), findsOneWidget);
    }
    expect(chordRole(ctl.harmony.shown!, 11), ChordRole.third); // B
    expect(chordRole(ctl.harmony.shown!, 5), ChordRole.seventh); // F
    for (final id in [41, 45, 25, 22]) {
      b.release(id);
    }
    await runFor(tester, 200);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('the proof sheet of accidentals renders at label sizes', (tester) async {
    for (final h in [48.0, 24.0, 11.0]) {
      final img = await tester.runAsync(() => accidentalSheet(h: h));
      expect(img!.width, greaterThan(100));
    }
    // widths: nothing for a natural, more strokes are wider, the flat side is at least as wide
    expect(qtAccidentalWidth(24, 0.0), 0);
    expect(qtAccidentalWidth(24, 0.05), 0);
    expect(qtAccidentalWidth(24, 1), lessThan(qtAccidentalWidth(24, 2)));
    expect(qtAccidentalWidth(24, 2), lessThan(qtAccidentalWidth(24, 3)));
    expect(qtAccidentalWidth(24, 2.5), qtAccidentalWidth(24, 3)); // the partial third stroke has its room
    expect(qtAccidentalWidth(24, -2), greaterThan(0));
    expect(qtAccidentalWidth(24, -3), greaterThan(qtAccidentalWidth(24, -2)));
    expect(File('assets/fonts/Inter.ttf').existsSync(), isTrue);
  });
}
