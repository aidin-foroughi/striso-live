// The app's controller against the virtual Striso (the firmware's own code, striso_virtual):
// as the USB board (a fake USB backend whose transport is a virtual board) and as Virtual (what
// Demo was): connect, the lists, voice switch, a live parameter and its undo, A/B, touch and key
// parameters, StcK tunings and the quarter-tone labels, the settings overlay's clicks, Save to
// Striso through the virtual board's bootloader drive, a reset and the reconnect; Virtual's sound.
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
    expect(ctl.mode, Mode.striso);
    expect(ctl.version!.line, startsWith(b.firmwareVersion));
    expect(ctl.voices.length, b.state.voices);
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
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    expect(ctl.virtual.isMock, isFalse);
    expect(ctl.status, startsWith('Virtual Striso'));
    expect(ctl.playable, isTrue);
    expect(ctl.voices.length, ctl.virtual.instrument!.board.state.voices);
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


  // --- the user's reports: Virtual silent without Through PC; sound changes "locked" -------------
  final audioLib = Platform.environment['STRISO_AUDIO_LIB'];
  final noAudio = skip != null || audioLib == null;

  AppController virtualApp({bool through = false, String? output}) {
    final backend = NativeAudioBackend.tryLoad(explicit: audioLib, backend: backendNull);
    final ctl = AppController(options: AppOptions(virtualLib: lib, noUsb: true), store: Store.memory(), audioBackend: backend);
    if (through) ctl.audio.setThrough(true);
    if (output != null) ctl.audio.setOutput(output);
    return ctl;
  }

  Future<int> framesIn(WidgetTester tester, VirtualBoard b, {int ms = 500}) async {
    final t0 = b.timeFrames;
    await settle(tester, ms: ms);
    return b.timeFrames - t0;
  }

  testWidgets('Virtual with Through PC off: the output plays the virtual board; voices, presets and settings keys change what plays', skip: noAudio, (
    tester,
  ) async {
    final ctl = virtualApp();
    await run(tester, ctl.start());
    expect(ctl.audio.through, isFalse);
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    final b = ctl.virtual.instrument!.board;
    await waitFor(tester, () => ctl.routing.heard, ms: 4000);
    expect(b.realtime, isFalse, reason: 'clocked by the output');
    expect(await framesIn(tester, b), greaterThan(4800), reason: 'the output renders the virtual board');
    expect(ctl.soundLine, contains('Virtual Striso'));
    expect(ctl.soundLine, contains('→'));
    expect(ctl.audio.route, AudioRoute.source);
    // voice, then a preset of it, from the app: the board's synth follows, every time
    for (final engine in ['bowed', 'ep', 'va']) {
      final vs = ctl.voices.where((x) => x.engine == engine).take(2).toList();
      for (final v in vs) {
        await run(tester, ctl.selectVoice(v.index));
        await waitFor(tester, () => ctl.voiceName == v.name);
        expect(b.state.voice, v.index, reason: v.name);
      }
    }
    // a settings key (the overlay): the voice key for bowed (24)
    ctl.toggleSettings(true);
    expect(ctl.settingsClick(24), isTrue);
    await waitFor(tester, () => ctl.voiceName.startsWith('bowed:'));
    expect(ctl.voices[b.state.voice].name, startsWith('bowed:'));
    // Settings + the ep key (28) on the instrument (the on-screen board plays its keys): the
    // firmware switches, the app follows
    final pl = ctl.playBoard!;
    pl.control(Idc.alt, true);
    await settle(tester, ms: 60);
    pl.press(28, pres: 0.4);
    await settle(tester, ms: 60);
    pl.release(28);
    pl.control(Idc.alt, false);
    await waitFor(tester, () => ctl.voices[b.state.voice].name.startsWith('ep:'));
    await waitFor(tester, () => ctl.voiceName.startsWith('ep:'));
    await run(tester, ctl.userDisconnect());
    expect(ctl.audio.route, AudioRoute.off);
    expect(ctl.virtual.instrument, isNull, reason: 'Disconnect stops the virtual Striso');
    await finish(tester, ctl);
  });

  testWidgets('Virtual with Through PC on: Through PC is the Striso\'s: Virtual plays its own output, Through PC stays as chosen', skip: noAudio, (
    tester,
  ) async {
    final ctl = virtualApp(through: true);
    await run(tester, ctl.start());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.routing.heard, ms: 4000);
    expect(ctl.audio.route, AudioRoute.source, reason: 'no Striso input in Virtual');
    expect(ctl.audio.through, isTrue);
    await run(tester, ctl.userDisconnect());
    expect(ctl.audio.through, isTrue);
    await finish(tester, ctl);
  });

  testWidgets('a dead output never freezes the virtual board: no sound, said so, and voice changes still land', skip: noAudio, (tester) async {
    final ctl = virtualApp(output: 'no such output');
    await run(tester, ctl.start());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    final b = ctl.virtual.instrument!.board;
    await settle(tester, ms: 600);
    expect(await framesIn(tester, b), greaterThan(4800), reason: 'the board runs on its own clock');
    final violin = ctl.voices.firstWhere((x) => x.engine == 'bowed');
    await run(tester, ctl.selectVoice(violin.index));
    await waitFor(tester, () => ctl.voiceName == violin.name);
    expect(b.state.voice, violin.index);
    await run(tester, ctl.userDisconnect());
    await finish(tester, ctl);
  });

  testWidgets('MIDI: bytes from a controller reach the virtual firmware’s own MIDI input unchanged (its MIDI monitor, StcM)', skip: noAudio, (
    tester,
  ) async {
    final ctl = virtualApp();
    expect(ctl.midi, isNotNull, reason: 'the audio library has the MIDI inputs');
    await run(tester, ctl.start());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    expect(ctl.midi!.running, isTrue, reason: 'MIDI runs while Virtual is live');
    final seen = <List<int>>[];
    final c = ctl.client!;
    final was = c.onStream!;
    c.onStream = (src, id, v, n) {
      if (src == Src.midi) seen.add([id, for (var i = 0; i < n; i++) v[i]]);
      was(src, id, v, n);
    };
    await run(tester, c.raw(0x4D)); // StcM: the firmware reports every MIDI message it gets
    // a controller (the library's test device: the same parser and sink as a real input)
    const bytes = [0x91, 60, 100, 0xD1, 80, 0xB1, 74, 70, 0xE1, 0x00, 0x48, 74, 71, 0xF8, 0x81, 60, 30];
    expect(ctl.midi!.backend.inject('test controller', bytes), greaterThanOrEqualTo(0));
    await waitFor(tester, () => seen.length >= 6, ms: 4000);
    // [channel, status nibble, data 1, data 2]: running status expanded, the clock (F8) dropped
    expect(seen, [
      [1, 0x9, 60, 100],
      [1, 0xD, 80, 0],
      [1, 0xB, 74, 70],
      [1, 0xE, 0x00, 0x48],
      [1, 0xE, 74, 71],
      [1, 0x8, 60, 30],
    ]);
    await run(tester, ctl.userDisconnect());
    expect(ctl.midi!.running, isFalse);
    await finish(tester, ctl);
  });
}
