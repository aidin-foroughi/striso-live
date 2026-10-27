// Not a test: renders each tab with Virtual (the firmware's own code, striso_virtual) into PNGs for
// a look (headless, no window, no audio device):
//   flutter test test/shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_play.png, prefix_sound.png, prefix_setup.png, prefix_recording.png (Through PC on,
// a fake audio input), prefix_equalizer.png, prefix_settings.png, prefix_stage.png,
// prefix_console.png.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

final width = const int.fromEnvironment('SHOT_W', defaultValue: 1600).toDouble();
final height = const int.fromEnvironment('SHOT_H', defaultValue: 1000).toDouble();

void main() {
  testWidgets('screenshots', skip: virtualSkip != null, (tester) async {
    if (shot.isEmpty) return;
    await loadShotFonts(tester);
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final audio = FakeAudioBackend()..documents = Directory.systemTemp.path;
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: virtualLib), store: Store.memory(), audioBackend: audio);
    ctl.setKey(root: 0, scale: 'major');
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));
    // real time for the board, fake time for the app, the fake audio input's frames
    Future<void> tick(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        audio.run(1920, level: 0.3);
        ctl.audio.tick();
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Future<void> save(String name) async {
      await tick(8);
      await savePng(tester, name);
    }

    await tapPlayVirtual(tester, ctl);
    ctl.audio.setThrough(true);
    await tick(40);
    ctl.saveCurrent('Warm classic');
    for (final id in [21, 23, 27, 29]) {
      press(ctl, [id], pres: 0.4);
      await tick(3);
      release(ctl, [id]);
      await tick(3);
    }
    const chord = [25, 29, 32];
    press(ctl, chord, pres: 0.6, x: 0.3, y: -0.2, strike: 0.5);
    await tick(20);
    await save('play');
    ctl.setTab(AppTab.sound);
    ctl.setMorphOpen(true);
    await save('sound');
    ctl.setTab(AppTab.setup);
    await save('setup');
    ctl.audio.startRecording();
    await tick(4);
    audio.run(48000 * 83);
    await save('recording');
    ctl.audio.stopRecording();
    await tick(4);
    ctl.setSetupMode(SetupMode.equalizer);
    ctl.eqSelect(27);
    await save('equalizer');
    ctl.setSetupMode(SetupMode.settings);
    ctl.settingsClick(24);
    await tick(10);
    await save('settings');
    ctl.setTab(AppTab.play);
    ctl.setKey(root: 0, scale: 'bh6dim');
    press(ctl, chord, pres: 0.7, strike: 0.3);
    await tick(10);
    ctl.setStage(true);
    await tick(12);
    await save('stage');
    ctl.setStage(false);
    await tick(12);
    ctl.setConsole(true);
    await save('console');
    release(ctl, chord);
    ctl.audio.setThrough(false);
    await finish(tester, ctl);
  });
}
