// Not a test: renders Setup › Audio (Through PC playing on the fake audio backend, the demo
// board's StcU counters), the Play tab with the trumpet, and the settings overlay into PNGs
// (headless, no window, no audio device):
//   flutter test test/audio_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_setup.png, prefix_play_trumpet.png, prefix_settings.png.
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'shot_test.dart' show loadFont;

const shot = String.fromEnvironment('SHOT');

String _materialIcons() {
  final cache = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  return '$cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

void main() {
  testWidgets('audio screenshots', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Inter', ['${Directory.current.path}/assets/fonts/Inter.ttf']);
      await loadFont('Georgia', ['C:/Windows/Fonts/georgia.ttf']);
      await loadFont('MaterialIcons', [_materialIcons()]);
      await loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
      await loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
    });
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    final audio = FakeAudioBackend(
      outputs: [
        const AudioDevice('Realtek Digital Output (Realtek(R) Audio)', id: 'realtek', transport: AudioTransport.builtin),
        const AudioDevice('Headphones (TBT200 Dock)', id: 'dock', transport: AudioTransport.usb, isDefault: true, devMin: 144, devDefault: 480),
        const AudioDevice('Speakers (EDIFIER MR5)', id: 'edifier', transport: AudioTransport.bluetooth),
      ],
    )..documents = Directory.systemTemp.path;
    // Auto knows this output: 128 frames played cleanly before
    final store = Store.memory()
      ..set('audio', const AudioPrefs(autoMemory: {'dock|exclusive': AutoMemory(stable: 128, failed: 64)}).toJson());
    final ctl = AppController(options: const AppOptions(noUsb: true), store: store, audioBackend: audio);
    ctl.setKey(root: 0, scale: 'major');
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));
    Future<void> run(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        audio.run(1920, level: 0.3);
        ctl.audio.tick();
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
    ctl.audio.setThrough(true);
    // the demo board's StcU poll (every 2 s) and the Striso buffer (Stct)
    await run(140);
    final b = ctl.demoBoard!;
    b.autoplay = false;

    ctl.selectEngine('trumpet');
    await run(30);
    for (final id in [25, 29, 32]) {
      b.press(id, pres: 0.6, x: 0.2, y: -0.1, strike: 0.4);
    }
    await run(20);
    await save('play_trumpet');
    for (final id in [25, 29, 32]) {
      b.release(id);
    }

    ctl.setTab(AppTab.setup);
    await run(10);
    await save('setup');

    ctl.setSetupMode(SetupMode.settings);
    ctl.settingsClick(15);
    await run(10);
    await save('settings');

    // end the demo session under real time and let its timers run out
    var done = false;
    ctl.endSession().then((_) => done = true);
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    ctl.audio.setThrough(false);
    for (var t = 0; t < 7000; t += 50) {
      ctl.audio.tick();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox());
    ctl.dispose();
  });
}
