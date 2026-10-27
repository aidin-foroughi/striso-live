// Through PC in the app, against the fake audio backend (no audio device), the Striso on USB
// being the virtual board (the real firmware): it plays only while the Striso is connected (the
// session's route), the choices survive a restart through settings.json, the header toggle and
// pip, Setup › Audio, recording with its time and Show in folder, and the header at the narrowest
// window.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/theme.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'support/virtual.dart';

/// The app with [fake] audio, its Striso on USB the virtual board [b].
Future<AppController> boot(WidgetTester tester, VirtualBoard b, FakeAudioBackend? fake, {Store? store, Size size = const Size(1600, 1500)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ctl = AppController(
    options: const AppOptions(),
    store: store ?? Store.memory(),
    usb: VirtualUsb(b),
    audioBackend: fake,
    backupDir: '${Directory.systemTemp.path}/striso_live_test_backups',
  );
  await tester.pumpWidget(StrisoLiveApp(ctl));
  await tester.pump();
  return ctl;
}

/// Connects the Striso (the virtual board) and waits for the lists.
Future<void> connect(WidgetTester tester, AppController ctl) async {
  await run(tester, ctl.userConnect());
  await waitFor(tester, () => ctl.state is Live && !ctl.listsLoading);
}

/// Ticks Through PC like its timer would, then lets the widgets catch up.
Future<void> ticks(WidgetTester tester, AppController ctl, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    ctl.audio.tick();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('striso_live_audio'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('off by default; the choices survive a restart (settings.json)', () {
    final path = '${tmp.path}${Platform.pathSeparator}settings.json';
    final fake = FakeAudioBackend();
    final a = AppController(options: const AppOptions(noUsb: true), store: Store(path), audioBackend: fake);
    expect(a.audio.prefs, const AudioPrefs());
    a.audio.tick();
    expect(fake.inited, isFalse, reason: 'nothing starts while it is off');
    a.audio.setThrough(true);
    a.audio.setGainDb(-12);
    a.audio.setOutput('Headphones (USB)');
    a.audio.setPeriod(64);
    a.audio.setExclusive(false);
    a.audio.setExclusiveOutput(true);
    a.dispose();
    expect(fake.inited, isFalse, reason: 'no session: the audio engine never started');

    final fake2 = FakeAudioBackend();
    final b = AppController(options: const AppOptions(noUsb: true), store: Store(path), audioBackend: fake2);
    expect(
      b.audio.prefs,
      const AudioPrefs(
        through: true,
        gainDb: -12,
        output: 'Headphones (USB)',
        period: 64,
        exclusive: false,
        exclusiveOutput: true,
        exclusiveOutputNoted: true,
      ),
    );
    for (var i = 0; i < 4; i++) {
      b.audio.tick();
    }
    expect(fake2.last.run, isFalse, reason: 'Through PC on, but no Striso session: nothing opens');
    expect(fake2.anyOpen, isFalse);
    b.audio.setRoute(AudioRoute.input); // what a Striso session does
    for (var i = 0; i < 4; i++) {
      b.audio.tick();
    }
    expect(
      fake2.last,
      AudioConfig(
        run: true,
        input: 'Striso Synth (Striso Synth)',
        output: 'Headphones (USB)',
        period: 64,
        monitor: true,
        exclusive: false,
        exclusiveOutput: Platform.isWindows, // exclusive output on a wired output, Windows only
      ),
    );
    expect(fake2.gain, closeTo(gainOf(-12), 1e-9));
    b.dispose();
  });

  testWidgets('header: the Through PC toggle plays the Striso, the pip follows the level', skip: virtualSkip != null, (tester) async {
    final fake = FakeAudioBackend();
    final b = await startBoard(tester);
    final ctl = await boot(tester, b, fake);
    expect(find.text('Through PC'), findsNothing, reason: 'only in Striso mode');
    await connect(tester, ctl);
    expect(find.text('Through PC'), findsOneWidget);
    final pip = find.byKey(const Key('through-pip'));
    expect((tester.widget<Pip>(pip)).hollow, isTrue);
    await tester.tap(find.byKey(const Key('through-toggle')));
    await ticks(tester, ctl);
    expect(fake.last.monitor, isTrue);
    expect(ctl.audio.playing, isTrue);
    fake.run(4800, level: 1.0);
    await ticks(tester, ctl, 1);
    expect(tester.widget<Pip>(pip).color, Pal.error, reason: 'full scale');
    fake.run(4800, level: 0.1);
    await ticks(tester, ctl, 1);
    expect(tester.widget<Pip>(pip).hollow, isFalse);
    expect(tester.widget<Pip>(pip).color, isNot(Pal.error));
    fake.unplug();
    await ticks(tester, ctl, 2);
    expect(tester.widget<Pip>(pip).color, Pal.error, reason: 'the input is gone');
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('Setup › Audio: devices, buffer, latency, status, Record and Show in folder', skip: virtualSkip != null, (tester) async {
    final fake = FakeAudioBackend();
    final b = await startBoard(tester);
    final ctl = await boot(tester, b, fake);
    await connect(tester, ctl);
    ctl.setTab(AppTab.setup);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('hear the Striso on this computer (its USB audio) while it plays'), findsOneWidget);
    await ticks(tester, ctl);
    expect(fake.enumerations, greaterThan(0), reason: 'the pickers ask for the devices');
    expect(find.text('Automatic: Striso Synth (Striso Synth)'), findsOneWidget);
    expect(find.text('Default (Speakers (Realtek))'), findsOneWidget);
    expect(find.byKey(const Key('audio-status')), findsOneWidget);
    expect(find.textContaining('Off. Turn on Through PC'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-through')));
    await ticks(tester, ctl);
    expect(find.textContaining('Playing through the computer · 48 kHz · 24-bit'), findsOneWidget);
    // Auto starts safe; the latency with its parts (in, ring, out, USB: the board's 2 ms default ring, the fetch, the bus)
    expect(find.text('Recommended · now 256 frames · the output wakes every 5.3 ms'), findsOneWidget);
    expect(find.text('10.6 ms'), findsOneWidget);
    expect(find.text('IN 0.5 · RING 2.0 · OUT 5.3 · USB ~2.7'), findsOneWidget);
    expect(find.text('0 in the last minute'), findsOneWidget);
    expect(find.text('BOARD 0 · INPUT 0 · OUTPUT 0'), findsOneWidget);

    // a dropout, by side
    fake.dropout(input: true);
    await ticks(tester, ctl, 1);
    expect(find.text('1 in the last minute'), findsOneWidget);
    expect(find.text('BOARD 0 · INPUT 1 · OUTPUT 0'), findsOneWidget);

    // a manual buffer
    await tester.tap(find.byKey(const Key('audio-buffer-128')));
    await ticks(tester, ctl, 2);
    expect(fake.last.period, 128);
    expect(find.byKey(const Key('audio-auto-line')), findsNothing);
    await tester.tap(find.byKey(const Key('audio-buffer-0')));
    await ticks(tester, ctl, 2);
    expect(ctl.audio.prefs.isAuto, isTrue);

    // record (to a temp folder through the documents dir)
    fake.documents = tmp.path;
    await tester.tap(find.byKey(const Key('audio-record')));
    await ticks(tester, ctl, 2);
    expect(ctl.audio.recording, isTrue);
    expect(fake.recordPaths.single, startsWith('${tmp.path}${Platform.pathSeparator}Striso Live Recordings${Platform.pathSeparator}Striso '));
    fake.run(48000 * 62);
    await ticks(tester, ctl, 1);
    expect(find.text('1:02 · 24-bit'), findsOneWidget);
    expect(find.byKey(const Key('rec-indicator')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('rec-indicator')), matching: find.text('1:02')), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-record'))); // Stop
    await ticks(tester, ctl, 2);
    expect(ctl.audio.recording, isFalse);
    expect(find.byKey(const Key('rec-indicator')), findsNothing);
    expect(find.byKey(const Key('audio-reveal')), findsOneWidget);
    expect(find.textContaining('.wav'), findsOneWidget);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('a Bluetooth output: a one-line note under the output, and under the header while it plays', skip: virtualSkip != null, (tester) async {
    final fake = FakeAudioBackend(outputs: [const AudioDevice('Speakers (EDIFIER MR5)', id: 'bt', transport: AudioTransport.bluetooth, isDefault: true)]);
    final b = await startBoard(tester);
    final ctl = await boot(tester, b, fake);
    await connect(tester, ctl);
    ctl.setTab(AppTab.setup);
    await tester.pump(const Duration(milliseconds: 300));
    await ticks(tester, ctl);
    expect(find.byKey(const Key('output-notice')), findsNothing, reason: 'the jack plays: nothing goes to Bluetooth');
    ctl.audio.setThrough(true);
    await ticks(tester, ctl);
    expect(tester.widget<Text>(find.byKey(const Key('audio-output-hint'))).data, bluetoothNotice);
    expect(find.descendant(of: find.byKey(const Key('output-notice')), matching: find.text(bluetoothNotice)), findsOneWidget);
    expect(fake.last.exclusiveOutput, isFalse);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('no audio library: the toggle is there but disabled, Setup says why', skip: virtualSkip != null, (tester) async {
    final b = await startBoard(tester);
    final ctl = await boot(tester, b, null);
    await connect(tester, ctl);
    ctl.setTab(AppTab.setup);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('through-toggle')), findsOneWidget);
    expect(find.textContaining('missing from this build'), findsWidgets);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('narrowest window, connected and recording: the header fits', skip: virtualSkip != null, (tester) async {
    final fake = FakeAudioBackend();
    final b = await startBoard(tester);
    final ctl = await boot(tester, b, fake, size: const Size(1000, 760));
    fake.documents = tmp.path;
    await connect(tester, ctl);
    ctl.audio.setThrough(true);
    ctl.audio.startRecording();
    await ticks(tester, ctl);
    expect(ctl.audio.recording, isTrue);
    expect(find.text('Through PC'), findsNothing, reason: 'the label folds away when narrow');
    // (Play and Setup: the Sound tab's top row overflows at 1000 px by itself, before Through PC)
    for (final t in [AppTab.play, AppTab.setup]) {
      ctl.setTab(t);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }
    expect(find.byKey(const Key('rec-indicator')), findsOneWidget);
    ctl.audio.stopRecording();
    await ticks(tester, ctl);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });
}
