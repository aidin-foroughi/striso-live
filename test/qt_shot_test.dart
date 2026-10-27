// Not a test: headless screenshots of the quarter-tone labels and the tonal colouring on Virtual
// (the firmware's own code, striso_virtual, its tunings; no window, no audio device).
//   flutter test test/qt_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_accidentals.png (the glyph proof sheet; _24, _12 at smaller sizes),
// prefix_pitch_31tet.png, prefix_cents_31tet.png, prefix_pitch_just.png, prefix_pitch_432.png (the
// firmware's fine tune 10 steps down: A = 432.1 Hz), prefix_colour_degree.png,
// prefix_colour_function.png, prefix_colour_chord.png, prefix_settings_tuning.png.
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/ui/accidentals.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

final width = const int.fromEnvironment('SHOT_W', defaultValue: 1600).toDouble();
final height = const int.fromEnvironment('SHOT_H', defaultValue: 1000).toDouble();

void main() {
  testWidgets('quarter-tone and colour screenshots', skip: virtualSkip != null, (tester) async {
    if (shot.isEmpty) return;
    await loadShotFonts(tester);
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
    addTearDown(tester.view.reset);
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: virtualLib), store: Store.memory());
    ctl.setKey(root: 0, scale: 'major');
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));

    Future<void> save(String name) async {
      await settle(tester, ms: 320);
      await savePng(tester, name);
    }

    /// One of the board's tunings, loaded by its settings key.
    Future<void> tuning(int n) async {
      ctl.loadTuning(n);
      await waitFor(tester, () => ctl.tuning?.index == n);
    }

    /// The firmware's fine tune (its dial), set from the console.
    Future<void> fine(double cents) async {
      final d = ctl.dials!.firstWhere((x) => x.name == 'fine');
      await run(tester, ctl.client!.setDial(d.id, cents));
      await waitFor(tester, () => ((ctl.tuning?.offsetCents ?? 0) - cents).abs() < 0.01);
    }

    await playVirtual(tester, ctl);
    await waitFor(tester, () => ctl.tuningSupported == true && ctl.dials != null);
    // pitch labels in 31-TET with a chord held
    const chord = [25, 29, 32];
    ctl.setNames(Names.pitch);
    await tuning(1);
    press(ctl, chord, pres: 0.6, x: 0.3, y: -0.2, strike: 0.5);
    await settle(tester, ms: 800);
    await save('pitch_31tet');
    ctl.setNames(Names.cents);
    await save('cents_31tet');
    ctl.setNames(Names.pitch);
    await tuning(8);
    await save('pitch_just');
    await tuning(0);
    await fine(-31.25);
    await save('pitch_432');
    release(ctl, chord);
    // colouring
    await fine(0);
    ctl.setNames(Names.degrees);
    ctl.setColour(KeyColour.degree);
    await save('colour_degree');
    ctl.setKey(root: 9, scale: 'harmonic');
    ctl.setNames(Names.letters);
    ctl.setColour(KeyColour.function);
    await save('colour_function');
    ctl.setKey(root: 0, scale: 'major');
    ctl.setColour(KeyColour.chord);
    // G7: G3 B3 D4 F4
    const g7 = [41, 45, 25, 22];
    press(ctl, g7, pres: 0.55, strike: 0.4);
    await waitFor(tester, () => ctl.harmony.shown?.name == 'G7');
    await save('colour_chord');
    release(ctl, g7);
    await settle(tester, ms: 400);
    // the settings overlay with the current tuning named on its key
    ctl.setColour(KeyColour.off);
    await tuning(1);
    ctl.setTab(AppTab.setup);
    ctl.setSetupMode(SetupMode.settings);
    ctl.settingsClick(ctl.settingsLayout.keys.entries.firstWhere((e) => e.value.tuningIndex == 1).key);
    await settle(tester, ms: 800);
    await save('settings_tuning');
    ctl.setTab(AppTab.play);
    await finish(tester, ctl);
  });
}
