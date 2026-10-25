// The board's presets in the Play column, on the Dart mock (it answers the preset commands as
// doc/presets_console.md has them): ON THE STRISO lists the user's presets for the engine, Save
// as… with a title and description, Load (the board's report under the header when the preset
// was made for another version), Share… (the board's text, as it is), Install (a file sent as it
// is, the board's reason when it refuses), Delete after a confirm; a firmware without a store.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'flows_test.dart' show boot, finish, pumpUntil, settle, untilLive;

void main() {
  testWidgets('presets on the Striso: save as, load, share, install with the report, delete', (tester) async {
    final dir = Directory.systemTemp.createTempSync('presets_ui');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final sep = Platform.pathSeparator;
    final ctl = await boot(tester, AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store.memory()));
    await pumpUntil(tester, ctl.playVirtual());
    await untilLive(tester, ctl);
    for (var i = 0; i < 40 && ctl.boardPresets == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 50);
    }
    expect(ctl.boardPresets, isNotNull, reason: 'listed once live (StcJ)');
    expect(ctl.boardPresets!.presets.length, ctl.voices.length, reason: 'the factory presets are the voice entries');
    expect(find.text('ON THE STRISO'), findsOneWidget);
    expect(find.text('Presets you save on the Striso appear here.'), findsOneWidget);

    // Save as…: a title and a description; the board writes the preset
    await tester.tap(find.byKey(const Key('preset-save-as')));
    await settle(tester, 300);
    await tester.enterText(find.descendant(of: find.byKey(const Key('preset-title')), matching: find.byType(TextField)), 'Warm classic');
    await tester.enterText(find.descendant(of: find.byKey(const Key('preset-description')), matching: find.byType(TextField)), 'Slow and dark.');
    await settle(tester, 100);
    await tester.tap(find.byKey(const Key('preset-save')));
    await settle(tester, 200);
    for (var i = 0; i < 40 && ctl.boardPresets!.user.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 50);
    }
    final mine = ctl.boardPresets!.user.single;
    expect((mine.title, mine.description, mine.engine), ('Warm classic', 'Slow and dark.', ctl.currentEngine));
    expect(
      find.descendant(of: find.byKey(Key('board-preset-${mine.id}')), matching: find.text('Warm classic')),
      findsOneWidget,
      reason: 'listed under ON THE STRISO',
    );
    // a title the board cannot keep is said before anything is sent
    expect(AppController.presetFieldsProblem('Café', ''), contains('ASCII'));
    expect(AppController.presetFieldsProblem('x' * 64, ''), contains('63'));

    // Load: a preset of this engine's version loads exactly, no report
    final r = await pumpUntil(tester, ctl.openBoardPreset(mine));
    expect(r!.exact, isTrue);
    expect(ctl.banner, isNull);
    expect(ctl.openPreset?.id, mine.id, reason: 'the preset plays, on the voice the board named');
    expect(ctl.soundTitle, 'Warm classic');
    // another voice: no longer the preset
    final pad = ctl.voices.firstWhere((v) => v.name == 'va:pad');
    await pumpUntil(tester, ctl.selectVoice(pad.index));
    expect(ctl.openPreset, isNull);
    expect(ctl.soundTitle, 'pad');

    // Share…: the board's text, byte for byte
    final shared = '${dir.path}${sep}warm.preset.json';
    expect(await pumpUntil(tester, ctl.sharePreset(mine, shared)), isTrue);
    final file = jsonDecode(File(shared).readAsStringSync()) as Map<String, Object?>;
    expect(file['title'], 'Warm classic');
    expect(file['format'], 'awva-preset/1');

    // Install: a preset from an older engine; the board's report when it is loaded
    final old = File('${dir.path}${sep}old.preset.json')
      ..writeAsStringSync(
        jsonEncode({
          'format': 'awva-preset/1',
          'engine': {'id': 'va', 'version': 'v2.2.4-200', 'params_hash': '00000000'},
          'title': 'Older lead',
          'params': {'gain': 99, 'old_knob': 1},
        }),
      );
    final inst = await pumpUntil(tester, ctl.installPresetFile(old.path));
    expect(inst, isNotNull);
    expect(inst!.title, 'Older lead');
    final o = await pumpUntil(tester, ctl.openBoardPreset(inst));
    expect(o!.exact, isFalse);
    expect(ctl.banner?.text, contains('clamped'));
    expect(ctl.banner?.text, contains('gain'));
    expect(ctl.banner?.text, contains('old_knob'));
    // refused with the board's reason, in words
    final flute = File('${dir.path}${sep}flute.preset.json')..writeAsStringSync(File(old.path).readAsStringSync().replaceAll('"va"', '"flute"'));
    expect(await pumpUntil(tester, ctl.installPresetFile(flute.path)), isNull);
    expect(ctl.toasts.value.last.text, contains('its engine (flute) is not on this Striso'));
    final junk = File('${dir.path}${sep}junk.json')..writeAsStringSync('{not json');
    expect(await pumpUntil(tester, ctl.installPresetFile(junk.path)), isNull);
    expect(ctl.toasts.value.last.text, contains('not a preset file'));

    // Delete, after the confirm
    await settle(tester, 300);
    final row = find.byKey(Key('board-preset-${mine.id}'));
    expect(row, findsOneWidget);
    expect(await pumpUntil(tester, ctl.deleteBoardPreset(mine)), isTrue);
    await settle(tester, 200);
    expect(find.byKey(Key('board-preset-${mine.id}')), findsNothing);
    expect(ctl.boardPresets!.user.map((p) => p.title), ['Older lead']);
    await finish(tester, ctl);
  });

  testWidgets('a firmware without a preset store: factory presets only, said once', (tester) async {
    final ctl = await boot(tester, AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store.memory()));
    await pumpUntil(tester, ctl.playVirtual());
    await untilLive(tester, ctl);
    ctl.virtual.mock!.presetStore = false;
    await pumpUntil(tester, ctl.refreshBoardPresets());
    await settle(tester, 200);
    expect(ctl.boardPresets!.storeOn, isFalse);
    expect(find.textContaining('keeps no presets of your own'), findsOneWidget);
    expect(find.byKey(const Key('preset-save-as')), findsNothing);
    await finish(tester, ctl);
  });
}
