// Screenshots of the board's presets in the Play column, on Virtual (the firmware's own code,
// striso_virtual, and its preset store):
//   flutter test test/presets_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_list.png (ON THE STRISO with two presets), prefix_saveas.png (the Save as… dialog),
// prefix_report.png (an older engine's preset loaded: the board's report under the header).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

void main() {
  testWidgets('presets screenshots', skip: virtualSkip != null, (tester) async {
    if (shot.isEmpty) return;
    await loadShotFonts(tester);
    final dir = Directory.systemTemp.createTempSync('presets_shot');
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: virtualLib), store: Store.memory());
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));

    Future<void> save(String name) async {
      await settle(tester, ms: 320);
      await savePng(tester, name);
    }

    await playVirtual(tester, ctl);
    await waitFor(tester, () => ctl.boardPresets != null);
    await run(tester, ctl.savePresetAs('Warm classic', 'Slow attack, dark, a little detuned.'));
    final old = File('${dir.path}${Platform.pathSeparator}old.preset.json')
      ..writeAsStringSync(
        jsonEncode({
          'format': 'awva-preset/1',
          'engine': {'id': 'va', 'version': 'v2.2.4-200', 'params_hash': '00000000'},
          'title': 'Older lead',
          'params': {'gain': 99, 'old_knob': 1},
        }),
      );
    final p = await run(tester, ctl.installPresetFile(old.path));
    await settle(tester, ms: 3200); // the toast goes
    await save('list');
    await tester.tap(find.byKey(const Key('preset-save-as')));
    await settle(tester, ms: 240);
    await save('saveas');
    await tester.tapAt(const Offset(5, 990));
    await settle(tester, ms: 240);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester, ms: 240);
    await run(tester, ctl.openBoardPreset(p!));
    await save('report');
    await finish(tester, ctl);
    dir.deleteSync(recursive: true);
  });
}
