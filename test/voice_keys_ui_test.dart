// The voice keys in the app (Setup, Settings keys; an engine's "Put on key…"), on Virtual, the
// firmware's own code (striso_virtual), which answers Stca and StcA: the keys, the engines on them
// and the factory ones are the firmware's.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('voice-key-status'))).data!;

/// The voice keys with nothing on them, in key order, as the board lists them (Stca).
List<int> freeKeys(AppController ctl) => [
  for (final s in ctl.voiceKeys.slots)
    if (s.empty) s.key,
]..sort();

void main() {
  final skip = virtualSkip != null;

  testWidgets('Settings keys: a free voice key gets an engine and a preset; a key back to its factory engine, or none', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await waitFor(tester, () => ctl.voiceKeys.slots.isNotEmpty);
    final free = freeKeys(ctl).first;
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    await settle(tester, ms: 300);

    // a free key: selected, it says so and offers the engines
    expect(ctl.settingsClick(free), isTrue);
    await settle(tester, ms: 300);
    expect(ctl.settingsSelected, free);
    expect(find.byKey(Key('voice-key-$free')), findsOneWidget);
    expect(status(tester), 'No voice on this key.');
    await tester.tap(find.byKey(const Key('voice-key-engine-modal')));
    await waitFor(tester, () => ctl.voiceKeys[free]?.engine == 'modal' && ctl.lastVoiceKeyUndo?.$1 == free);
    await settle(tester, ms: 100);
    expect(ctl.voiceKeys[free]!.plays, isTrue);
    expect(find.byKey(const Key('voice-key-unsaved')), findsOneWidget);
    // a preset to start on
    final second = ctl.voices.where((v) => v.engine == 'modal').elementAt(1);
    await tester.tap(find.byKey(Key('voice-key-preset-${second.index}')));
    await waitFor(tester, () => ctl.voiceKeys[free]?.preset == second.preset);
    expect(ctl.voiceKeys.edits.map((e) => e.key), containsAll(['sGv${free}a', 'sGv${free}p']));

    // the trumpet's key: no voice, then the factory engine again
    final trumpet = ctl.voiceKeys.keysOf('trumpet').single;
    expect(ctl.voiceKeys[trumpet]!.isFactory, isTrue);
    expect(ctl.settingsClick(trumpet), isTrue);
    await settle(tester, ms: 300);
    await tester.tap(find.byKey(const Key('voice-key-clear')));
    await waitFor(tester, () => ctl.voiceKeys[trumpet]?.empty == true && ctl.lastVoiceKeyUndo?.$1 == trumpet);
    await settle(tester, ms: 200);
    expect(find.byKey(const Key('voice-key-factory')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-key-factory')));
    await waitFor(tester, () => ctl.voiceKeys[trumpet]?.engine == 'trumpet');
    expect(ctl.voiceKeys[trumpet]!.isFactory, isTrue);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });

  testWidgets('an engine\'s Put on key: free keys first; in place of another engine, with Undo', skip: skip, (tester) async {
    final ctl = await bootApp(tester);
    await tapPlayVirtual(tester, ctl);
    await waitFor(tester, () => ctl.voiceKeys.slots.isNotEmpty);
    final bowed = ctl.voiceKeys.keysOf('bowed').single, wind = ctl.voiceKeys.keysOf('wind').single;
    ctl.setTab(AppTab.play);
    await settle(tester, ms: 300);
    // a right click on the bowed engine: the keys, the free ones first
    await tester.tap(find.byKey(const Key('engine-bowed')), buttons: kSecondaryButton);
    await settle(tester, ms: 400);
    final items = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('put-on-'));
    final order = [for (final e in items.evaluate()) int.parse((e.widget.key! as ValueKey<String>).value.substring(7))];
    final free = freeKeys(ctl);
    expect(free, isNotEmpty);
    expect(order.take(free.length), free);
    // in place of the wind
    await tester.tap(find.byKey(Key('put-on-$wind')));
    await waitFor(tester, () => ctl.voiceKeys[wind]?.engine == 'bowed' && ctl.lastVoiceKeyUndo != null);
    await settle(tester, ms: 100);
    expect(ctl.voiceKeys.keysOf('bowed'), [bowed, wind]..sort());
    expect(ctl.lastVoiceKeyUndo?.$1, wind);
    // Undo: the wind back on its key
    await tester.tap(find.text('Undo'));
    await waitFor(tester, () => ctl.voiceKeys[wind]?.engine == 'wind' && ctl.voiceKeys.saved);
    expect(ctl.voiceKeys[wind]!.isFactory, isTrue);
    expect(ctl.voiceKeys.saved, isTrue);
    expect(tester.takeException(), isNull);
    await finish(tester, ctl);
  });
}
