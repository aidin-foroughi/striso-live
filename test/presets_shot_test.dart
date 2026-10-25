// Screenshots of the board's presets in the Play column, on the Dart mock:
//   flutter test test/presets_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_list.png (ON THE STRISO with two presets), prefix_saveas.png (the Save as… dialog),
// prefix_menu.png (a preset's Load / Share… / Delete), prefix_report.png (an older engine's
// preset loaded: the board's report under the header).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'flows_shot_test.dart' show loadFont;

const shot = String.fromEnvironment('SHOT');

void main() {
  testWidgets('presets screenshots', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Inter', ['${Directory.current.path}/assets/fonts/Inter.ttf']);
      await loadFont('Georgia', ['C:/Windows/Fonts/georgia.ttf']);
      final cache = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
      await loadFont('MaterialIcons', ['$cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
      await loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
      await loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('presets_shot');
    final ctl = AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store.memory());
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));

    Future<void> run(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Future<T> wait<T>(Future<T> f) async {
      var done = false;
      late T v;
      f.then((x) {
        v = x;
        done = true;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await run(1);
      }
      return v;
    }

    Future<void> save(String name) async {
      await run(8);
      final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final png = await tester.runAsync(() async {
        final img = await ro.toImage();
        final d = await img.toByteData(format: dui.ImageByteFormat.png);
        return d?.buffer.asUint8List();
      });
      File('${shot}_$name.png').writeAsBytesSync(png!);
    }

    await wait(ctl.playVirtual());
    for (var i = 0; i < 60 && (ctl.listsLoading || ctl.boardPresets == null); i++) {
      await run(2);
    }
    await wait(ctl.savePresetAs('Warm classic', 'Slow attack, dark, a little detuned.'));
    final old = File('${dir.path}${Platform.pathSeparator}old.preset.json')
      ..writeAsStringSync(
        jsonEncode({
          'format': 'awva-preset/1',
          'engine': {'id': 'va', 'version': 'v2.2.4-200', 'params_hash': '00000000'},
          'title': 'Older lead',
          'params': {'gain': 99, 'old_knob': 1},
        }),
      );
    final p = await wait(ctl.installPresetFile(old.path));
    await run(80); // the toast goes
    await save('list');
    await tester.tap(find.byKey(const Key('preset-save-as')));
    await run(6);
    await save('saveas');
    await tester.tapAt(const Offset(5, 990));
    await run(6);
    await tester.tapAt(const Offset(5, 5));
    await run(6);
    await wait(ctl.openBoardPreset(p!));
    await save('report');
    await ctl.endSession();
    await run(10);
    await tester.pumpWidget(const SizedBox());
    ctl.dispose();
    dir.deleteSync(recursive: true);
  });
}
