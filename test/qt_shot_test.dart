// Not a test: headless screenshots of the quarter-tone labels and the tonal colouring with the
// demo board (no window).
//   flutter test test/qt_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_accidentals.png (the glyph proof sheet), prefix_pitch_31tet.png, prefix_pitch_just.png,
// prefix_pitch_432.png, prefix_cents_31tet.png, prefix_colour_degree.png, prefix_colour_function.png,
// prefix_colour_chord.png.
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/ui/accidentals.dart';

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

String _materialIcons() {
  final cache = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  return '$cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

void main() {
  testWidgets('quarter-tone and colour screenshots', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Inter', ['${Directory.current.path}/assets/fonts/Inter.ttf']);
      await loadFont('Georgia', ['C:/Windows/Fonts/georgia.ttf']);
      await loadFont('MaterialIcons', [_materialIcons()]);
      await loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
    });
    // the glyph proof sheet at three sizes
    await tester.runAsync(() async {
      for (final (h, name) in [(48.0, 'accidentals'), (24.0, 'accidentals_24'), (12.0, 'accidentals_12')]) {
        final img = await accidentalSheet(h: h);
        final d = await img.toByteData(format: dui.ImageByteFormat.png);
        File('${shot}_$name.png').writeAsBytesSync(d!.buffer.asUint8List());
      }
    });
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    final audio = FakeAudioBackend()..documents = Directory.systemTemp.path;
    final ctl = AppController(options: const AppOptions(noUsb: true), store: Store.memory(), audioBackend: audio);
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
    // the performer's notes stay held once autoplay stops: let go of them
    for (final id in b.keys.keys.toList()) {
      b.release(id);
    }
    await run(15);
    // pitch labels in 31-TET with a chord held
    ctl.setNames(Names.pitch);
    ctl.demoTuning(1);
    await run(20);
    for (final id in [25, 29, 32]) {
      b.press(id, pres: 0.6, x: 0.3, y: -0.2, strike: 0.5);
    }
    await run(20);
    await save('pitch_31tet');
    ctl.setNames(Names.cents);
    await run(10);
    await save('cents_31tet');
    ctl.setNames(Names.pitch);
    ctl.demoTuning(8);
    await run(20);
    await save('pitch_just');
    ctl.demoTuning(0, fineCents: -31.77);
    await run(20);
    await save('pitch_432');
    for (final id in [25, 29, 32]) {
      b.release(id);
    }
    // colouring
    ctl.demoTuning(0, fineCents: 0);
    ctl.setNames(Names.degrees);
    ctl.setColour(KeyColour.degree);
    await run(20);
    await save('colour_degree');
    ctl.setKey(root: 9, scale: 'harmonic');
    ctl.setNames(Names.letters);
    ctl.setColour(KeyColour.function);
    await run(20);
    await save('colour_function');
    ctl.setKey(root: 0, scale: 'major');
    ctl.setColour(KeyColour.chord);
    // G7: G3 B3 D4 F4
    for (final id in [41, 45, 25, 22]) {
      b.press(id, pres: 0.55, strike: 0.4);
    }
    await run(30);
    await save('colour_chord');
    for (final id in [41, 45, 25, 22]) {
      b.release(id);
    }
    await run(10);
    // the settings overlay with the current tuning named on its key
    ctl.setColour(KeyColour.off);
    ctl.demoTuning(1);
    await run(10);
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    ctl.settingsClick(36);
    await run(20);
    await save('settings_tuning');
    ctl.setTab(AppTab.play);
    await ctl.endSession();
    await run(4);
    await tester.pumpWidget(const SizedBox());
    ctl.dispose();
  });
}
