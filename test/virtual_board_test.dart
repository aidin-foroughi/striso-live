// The app's controller against the virtual Striso (the firmware's own code, striso_virtual):
// as the USB board (a fake USB backend whose transport is a virtual board) and as Virtual (what
// Demo was): connect, the lists, voice switch, a live parameter and its undo, A/B, touch and key
// parameters, StcK tunings and the quarter-tone labels, the settings overlay's clicks, Save to
// Striso through the virtual board's bootloader drive, a reset and the reconnect, the audition.
// Needs the library (cmake --build --preset host-virtual in the firmware checkout; found as the
// striso_virtual package finds it); skips with the reason otherwise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_virtual/striso_virtual.dart';

/// A USB backend whose Striso is a virtual board.
class VirtualUsb implements UsbBackend {
  final VirtualBoard board;
  VirtualUsb(this.board);
  @override
  Future<({bool present, String where})> probe() async => (present: board.attached, where: 'virtual');
  @override
  Transport transport() => VirtualBoardTransport(board);
  @override
  Future<void> dispose() async {}
}

String? _lib() {
  try {
    return StrisoVirtualLib.load().path;
  } catch (_) {
    return null;
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() cond, {int ms = 10000}) async {
  for (var t = 0; t < ms && !cond(); t += 20) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(cond(), isTrue, reason: 'condition not met in $ms ms');
}

/// Lets the app's timers (the client's writes, the transport's poll) and the board run a while.
Future<void> settle(WidgetTester tester, {int ms = 200}) async {
  for (var t = 0; t < ms; t += 10) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

Future<T> run<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T v;
  f.then((x) {
    v = x;
    done = true;
  });
  await waitFor(tester, () => done);
  return v;
}

Future<void> finish(WidgetTester tester, AppController ctl) async {
  await run(tester, ctl.endSession());
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100)); // the app's timers run out
  }
  ctl.dispose();
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
}

void main() {
  final lib = _lib();
  final skip = lib == null ? 'striso_virtual not built' : null;

  testWidgets('the controller on the virtual board as the USB Striso: lists, voices, undo, A/B, touch, tunings, settings keys', skip: skip != null, (
    tester,
  ) async {
    late VirtualBoard b;
    await tester.runAsync(() async => b = VirtualBoard(libPath: lib)..startRealtime());
    final ctl = AppController(options: const AppOptions(), store: Store.memory()..set('usbIntent', 'connected'), usb: VirtualUsb(b));
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
    expect(ctl.mode, ConnMode.usb);
    expect(ctl.version!.line, startsWith(b.firmwareVersion));
    expect(ctl.voices.length, 56);
    expect(ctl.voiceName, 'va:classic');

    // voice switch
    final violin = ctl.voices.firstWhere((v) => v.name == 'bowed:violin');
    await run(tester, ctl.selectVoice(violin.index));
    await waitFor(tester, () => ctl.voiceName == 'bowed:violin' && ctl.params[0]!.params.isNotEmpty);

    // a live parameter and its undo: the board has the value, then the old one again
    final p = ctl.params[0]!.params.firstWhere((x) => x.kind == Kind.continuous);
    final was = p.value;
    ctl.onEdit(0, p, p.min + 0.3 * (p.max - p.min), 'begin', 'Edit');
    ctl.onEdit(0, p, p.min + 0.3 * (p.max - p.min), 'end');
    await settle(tester);
    final onBoard = await run(tester, ctl.client!.getParams(0));
    expect(onBoard!.params[p.index].value, conformValue(p, p.min + 0.3 * (p.max - p.min)));
    expect(ctl.edited, isTrue);
    // A/B: A is the preset on the board, B the edit
    ctl.setAB(true);
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, was);
    ctl.setAB(false);
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, isNot(was));
    ctl.undo();
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, was);

    // touch and key parameters
    final pres = ctl.findParam(2, 'pressure')!;
    ctl.setValue(2, pres, 1.6);
    final d3 = ctl.findParam(3, 'D_3')!;
    ctl.setValue(3, d3, 1.3);
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(2)))!.params[0].value, closeTo(1.6, 1e-6));
    expect((await run(tester, ctl.client!.getParams(3)))!.params[30].value, closeTo(1.3, 1e-6));

    // StcK: a tuning from the settings overlay, StcN, the quarter-tone labels
    ctl.toggleSettings(true);
    expect(ctl.settingsClick(38), isTrue); // tuning 2
    await waitFor(tester, () => ctl.tuning != null && ctl.tuning!.index == 2);
    expect(ctl.tuning!.isPlain12, isFalse);
    final id = keyIds.firstWhere((k) => ctl.qtLabel(k).centsFrom12.abs() > 1);
    expect(ctl.qtLabel(id).name, isNotEmpty);
    // a voice key on the overlay picks the engine (24: bowed, 20: va)
    expect(ctl.settingsClick(20), isTrue);
    await waitFor(tester, () => ctl.voiceName.startsWith('va:'));
    // a refused key: the panic key is allowed, the system reset (67) is not on the overlay
    expect(await run(tester, ctl.pressSettingsKey(63)), isTrue);
    ctl.toggleSettings(false);

    // a reset of the board: the app sees it go and comes back to it
    await tester.runAsync(() async {
      final pl = VirtualPlayer(b);
      pl.control(Idc.alt, true);
      pl.press(67, pres: 0.4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      pl.release(67);
      pl.control(Idc.alt, false);
    });
    await waitFor(tester, () => ctl.client == null);
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading, ms: 20000);
    expect(b.state.resets, 1);
    await finish(tester, ctl);
    await tester.runAsync(() async => b.dispose());
  });

  testWidgets('Virtual (what Demo was): the virtual board, played by hand, saved to its flash through its drive', skip: skip != null, (tester) async {
    final dir = await tester.runAsync(() async => Directory.systemTemp.createTempSync('sv_app'));
    final ctl = AppController(
      options: AppOptions(virtualLib: lib),
      store: Store.memory(),
      backupDir: dir!.path,
    );
    await run(tester, ctl.connectDemo());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    expect(ctl.virtual.isVirtual, isTrue);
    expect(ctl.virtual.pill, 'Virtual');
    expect(ctl.status, startsWith('Virtual Striso'));
    expect(ctl.playable, isTrue);
    expect(ctl.voices.length, 56);
    // playing it by hand: the stream shows the key
    ctl.playBoard!.press(30, pres: 0.5, strike: 0.6);
    await waitFor(tester, () => ctl.live.activeCount() > 0);
    ctl.playBoard!.release(30);
    // Save to Striso: StcB, the virtual drive, the restart, read back
    final pres = ctl.findParam(2, 'pressure')!;
    ctl.setValue(2, pres, 2.2);
    await settle(tester);
    expect(ctl.canSave(), isNull);
    await run(tester, ctl.doSave());
    expect(ctl.saveStatus.cls, 'ok', reason: ctl.saveStatus.text);
    await waitFor(tester, () => ctl.client != null && !ctl.listsLoading);
    expect(ctl.findParam(2, 'pressure')!.value, closeTo(2.2, 1e-6));
    await finish(tester, ctl);
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });

  final audio = Platform.environment['STRISO_AUDIO_LIB'];
  testWidgets(
    'the audition: the Striso plays the virtual board through the output source; muted, then restored',
    skip: skip != null || audio == null,
    (tester) async {
      late VirtualBoard real;
      await tester.runAsync(() async => real = VirtualBoard(libPath: lib, serial: 7)..startRealtime());
      final backend = NativeAudioBackend.tryLoad(explicit: audio, backend: backendNull);
      final ctl = AppController(
        options: AppOptions(virtualLib: lib),
        store: Store.memory()..set('usbIntent', 'connected'),
        usb: VirtualUsb(real),
        audioBackend: backend,
      );
      await run(tester, ctl.start());
      await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
      final level = ctl.findParam(1, 'level')!.value;
      expect(ctl.virtual.canAudition, isTrue);
      expect(await run(tester, ctl.virtual.startAudition()), isTrue);
      await waitFor(tester, () => ctl.virtual.auditioning && ctl.dot == Dot.demo && !ctl.listsLoading);
      expect(ctl.status, startsWith('Playing: virtual'));
      // the real board is muted; the virtual one runs in the output's callback
      final c = StrisoClient(VirtualBoardTransport(real));
      final t0 = ctl.virtual.board!.timeFrames;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600))); // real time: the device runs
      final st = backend!.status();
      expect(
        ctl.virtual.board!.timeFrames - t0,
        greaterThan(4800),
        reason: 'output: ${st.playback} err ${st.playbackError} cb ${st.playbackCallbacks} init ${st.initialised}',
      );
      // a key on the real board reaches the virtual board
      final pl = VirtualPlayer(real)..press(30, pres: 0.5, strike: 0.5);
      await waitFor(tester, () => ctl.virtual.board!.state.controls.any((v) => v[1] > 0));
      pl.release(30);
      pl.dispose();
      await run(tester, ctl.virtual.stopAudition());
      await waitFor(tester, () => ctl.mode == ConnMode.usb && ctl.dot == Dot.on && !ctl.listsLoading, ms: 15000);
      expect(ctl.findParam(1, 'level')!.value, level);
      await finish(tester, ctl);
      await tester.runAsync(() async {
        await c.disconnect();
        real.dispose();
      });
    },
  );
}
