// The tuning-aware labels and the colour modes, against the demo
// board (no USB, no window). Helpers come from widget_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/ui/accidentals.dart';

import 'widget_test.dart' show boot, finish, pumpUntil, runFor, settle, startDemo;

/// A demo board whose firmware predates N: the command is swallowed.
class _OldBoard extends MockBoard {
  _OldBoard() : super(autoplay: false, motionEnabled: false, idleFrames: 0);
  @override
  void receive(List<int> bytes) {
    if (bytes.length >= 4 && bytes[0] == 0x53 && bytes[1] == 0x74 && bytes[2] == 0x63 && bytes[3] == 0x4e) return;
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

  testWidgets('old firmware: no N reply means 12-TET from the layout', (tester) async {
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
