// Not a test: renders Setup › Audio (Through PC on, the fake audio backend's outputs), the Play
// tab with the trumpet, and the settings overlay into PNGs, on Virtual (the firmware's own code,
// striso_virtual; headless, no window, no audio device):
//   flutter test test/audio_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_setup.png, prefix_play_trumpet.png, prefix_settings.png.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

void main() {
  testWidgets('audio screenshots', skip: virtualSkip != null, (tester) async {
    if (shot.isEmpty) return;
    await loadShotFonts(tester);
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: virtualLib), store: store, audioBackend: audio);
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
    await tick(60);

    ctl.selectEngine('trumpet');
    await waitFor(tester, () => ctl.voiceName.startsWith('trumpet') && !ctl.listsLoading);
    await tick(20);
    const chord = [25, 29, 32];
    press(ctl, chord, pres: 0.6, x: 0.2, y: -0.1, strike: 0.4);
    await tick(20);
    await save('play_trumpet');
    release(ctl, chord);

    ctl.setTab(AppTab.setup);
    await tick(10);
    await save('setup');

    ctl.setSetupMode(SetupMode.settings);
    ctl.settingsClick(ctl.settingsLayout.keys.entries.firstWhere((e) => e.value.engine == 'trumpet').key);
    await tick(10);
    await save('settings');

    ctl.audio.setThrough(false);
    await finish(tester, ctl);
  });
}
