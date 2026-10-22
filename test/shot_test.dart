// Not a test: renders the app with the demo board into a PNG for a look (headless).
//   flutter test test/shot_test.dart --dart-define=SHOT=path/to/out.png
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

Future<void> loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('screenshot', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
      await loadFont('Cambria', [r'C:\Windows\Fonts\cambria.ttc']);
      await loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
      await loadFont('MaterialIcons', []);
    });
    tester.view.physicalSize = const Size(1600, 2200);
    tester.view.devicePixelRatio = 1;
    final ctl = AppController(options: const AppOptions(noUsb: true), store: Store.memory());
    ctl.setKey(root: 0, scale: 'major');
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));
    await tester.tap(find.byKey(const Key('btn-demo')));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final b = ctl.demoBoard!;
    b.autoplay = false;
    for (final id in [25, 29, 32]) {
      b.press(id, pres: 0.6, x: 0.3, y: -0.2, strike: 0.5);
    }
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
    final png = await tester.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 1);
      final d = await img.toByteData(format: dui.ImageByteFormat.png);
      return d!.buffer.asUint8List();
    });
    File(shot).writeAsBytesSync(png!);
  });
}
