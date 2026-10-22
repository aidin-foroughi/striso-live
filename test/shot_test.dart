// Not a test: renders each tab with the demo board into PNGs for a look (headless, no window).
//   flutter test test/shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_play.png, prefix_sound.png, prefix_setup.png, prefix_settings.png.
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

const shot = String.fromEnvironment('SHOT');
final width = const int.fromEnvironment('SHOT_W', defaultValue: 1600).toDouble();
final height = const int.fromEnvironment('SHOT_H', defaultValue: 1000).toDouble();

Future<void> loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('screenshots', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
      await loadFont('Cambria', [r'C:\Windows\Fonts\cambria.ttc']);
      await loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
      await loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
    });
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    final ctl = AppController(options: const AppOptions(noUsb: true), store: Store.memory());
    ctl.setKey(root: 0, scale: 'major');
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));
    Future<void> run(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Future<void> save(String name) async {
      await run(8);
      final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final png = await tester.runAsync(() async {
        final img = await ro.toImage(pixelRatio: 1);
        final d = await img.toByteData(format: dui.ImageByteFormat.png);
        return d!.buffer.asUint8List();
      });
      File('${shot}_$name.png').writeAsBytesSync(png!);
    }

    await tester.tap(find.byKey(const Key('btn-demo')));
    await run(40);
    final b = ctl.demoBoard!;
    b.autoplay = false;
    ctl.saveCurrent('Warm classic');
    for (final id in [21, 23, 27, 29]) {
      b.press(id, pres: 0.4, strike: 0);
      await run(3);
      b.release(id);
      await run(3);
    }
    for (final id in [25, 29, 32]) {
      b.press(id, pres: 0.6, x: 0.3, y: -0.2, strike: 0.5);
    }
    await run(20);
    await save('play');
    ctl.setTab(AppTab.sound);
    ctl.setMorphOpen(true);
    await save('sound');
    ctl.setTab(AppTab.setup);
    ctl.setEqOn(true);
    await save('setup');
    ctl.toggleSettings(true);
    await save('settings');
  });
}
