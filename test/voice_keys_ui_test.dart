// The voice keys in the app (Setup, Settings keys; an engine's "Put on key…"), against the demo
// board, which answers Stca and StcA as the firmware does. Helpers come from widget_test.dart.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';

import 'widget_test.dart' show boot, finish, runFor, settle, startDemo;

Future<void> waitFor(WidgetTester tester, bool Function() done, {int tries = 60}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await runFor(tester, 50);
  }
  expect(done(), isTrue, reason: 'did not happen');
}

String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('voice-key-status'))).data!;

void main() {
  testWidgets('Settings keys: a free voice key gets an engine and a preset; a key back to its factory engine, or none', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await waitFor(tester, () => ctl.voiceKeys.slots.isNotEmpty);
    expect(ctl.voiceKeys[12]!.empty, isTrue);
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    await settle(tester, 300);

    // key 12 is free: selected, it says so and offers the engines
    expect(ctl.settingsClick(12), isTrue);
    await settle(tester, 300);
    expect(ctl.settingsSelected, 12);
    expect(find.byKey(const Key('voice-key-12')), findsOneWidget);
    expect(status(tester), 'No voice on this key.');
    await tester.tap(find.byKey(const Key('voice-key-engine-modal')));
    await waitFor(tester, () => ctl.voiceKeys[12]?.engine == 'modal');
    expect(ctl.voiceKeys[12]!.plays, isTrue);
    expect(find.byKey(const Key('voice-key-unsaved')), findsOneWidget);
    // a preset to start on
    final second = ctl.voices.where((v) => v.engine == 'modal').elementAt(1);
    await tester.tap(find.byKey(Key('voice-key-preset-${second.index}')));
    await waitFor(tester, () => ctl.voiceKeys[12]?.preset == second.preset);
    expect(ctl.voiceKeys.edits.map((e) => e.key), containsAll(['sGv12a', 'sGv12p']));

    // the trumpet key: no voice, then the factory engine again
    expect(ctl.settingsClick(15), isTrue);
    await settle(tester, 300);
    await tester.tap(find.byKey(const Key('voice-key-clear')));
    await waitFor(tester, () => ctl.voiceKeys[15]?.empty == true);
    await settle(tester, 200);
    expect(find.byKey(const Key('voice-key-factory')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-key-factory')));
    await waitFor(tester, () => ctl.voiceKeys[15]?.engine == 'trumpet');
    expect(ctl.voiceKeys[15]!.isFactory, isTrue);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('an engine\'s Put on key: free keys first; in place of another engine, with Undo', (tester) async {
    final ctl = await boot(tester);
    await startDemo(tester, ctl);
    await waitFor(tester, () => ctl.voiceKeys.slots.isNotEmpty);
    ctl.setTab(AppTab.play);
    await settle(tester, 300);
    // a right click on the bowed engine: the keys, the free ones first
    await tester.tap(find.byKey(const Key('engine-bowed')), buttons: kSecondaryButton);
    await settle(tester, 400);
    final items = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('put-on-'));
    final order = [for (final e in items.evaluate()) int.parse((e.widget.key! as ValueKey<String>).value.substring(7))];
    expect(order.take(3), [10, 12, 14]);
    await tester.tap(find.byKey(const Key('put-on-26')));
    await waitFor(tester, () => ctl.voiceKeys[26]?.engine == 'bowed');
    expect(ctl.voiceKeys.keysOf('bowed'), [24, 26]);
    expect(ctl.lastVoiceKeyUndo?.$1, 26);
    // Undo: the wind back on its key
    await tester.tap(find.text('Undo'));
    await waitFor(tester, () => ctl.voiceKeys[26]?.engine == 'wind');
    expect(ctl.voiceKeys[26]!.isFactory, isTrue);
    expect(ctl.voiceKeys.saved, isTrue);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });
}
