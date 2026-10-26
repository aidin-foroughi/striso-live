// The app's controller against the virtual Striso (the firmware's own code, striso_virtual):
// as the USB board (a fake USB backend whose transport is a virtual board) and as Virtual (what
// Demo was): connect, the lists, voice switch, a live parameter and its undo, A/B, touch and key
// parameters, StcK tunings and the quarter-tone labels, the settings overlay's clicks, Save to
// Striso through the virtual board's bootloader drive, a reset and the reconnect; Virtual's sound.
// Needs the library (cmake --build --preset host-virtual in the firmware checkout; found as the
// striso_virtual package finds it); skips with the reason otherwise.
import 'dart:io';

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/app_log.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/firmware_library.dart';
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

/// [step]: the fake time each pump moves; 5 keeps it near the real time the board runs in (the
/// client's timeouts are on the fake clock).
Future<void> waitFor(WidgetTester tester, bool Function() cond, {int ms = 10000, int step = 20}) async {
  for (var t = 0; t < ms && !cond(); t += step) {
    await tester.pump(Duration(milliseconds: step));
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

Future<T> run<T>(WidgetTester tester, Future<T> f, {int seconds = 10, int step = 20}) async {
  var done = false;
  late T v;
  f.then((x) {
    v = x;
    done = true;
  });
  await waitFor(tester, () => done, ms: seconds * 1000, step: step);
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
    // the hero knobs are the firmware's (StcH): the engine's list, a preset's own, every name listed
    await waitFor(tester, () => ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().map((p) => p.name), ['force_hi', 'pos', 'rosin', 'bright', 'body_amt', 'damp', 'vibrato', 'ensemble']);
    expect(ctl.mainFx().map((p) => p.name), ['rvmix', 'dlmix']);
    expect(ctl.heroMissing, isEmpty);
    final section = ctl.voices.firstWhere((v) => v.name == 'bowed:section');
    await run(tester, ctl.selectVoice(section.index));
    await waitFor(tester, () => ctl.voiceName == 'bowed:section' && ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().first.name, 'ensemble', reason: 'the preset\u2019s own heroes');
    await run(tester, ctl.selectVoice(violin.index));
    await waitFor(tester, () => ctl.voiceName == 'bowed:violin' && ctl.mainKnobs().isNotEmpty);

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

    // the board changes behind the app's back (a console write the app does not interpret, the
    // instrument's own buttons): the app shows what the board then reports, by its change counter
    expect(ctl.settingsLayout[24]!.engine, 'bowed', reason: 'the overlay is the firmware\u2019s (StcX)');
    final cello = ctl.voices.firstWhere((v) => v.name == 'bowed:cello');
    await run(tester, ctl.client!.send(selectVoiceCommand(cello.index)));
    await waitFor(tester, () => ctl.voiceName == 'bowed:cello' && ctl.boardState?.voice == cello.index);
    await run(tester, ctl.client!.send(settingsKeyCommand(36))); // tuning 1, pressed by someone else
    await waitFor(tester, () => ctl.boardState?.tuning == 1 && ctl.tuning?.index == 1);
    await tester.runAsync(() async {
      final pl = VirtualPlayer(b);
      pl.control(Idc.alt, true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pl.control(Idc.octUp, true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pl.control(Idc.octUp, false);
      pl.control(Idc.alt, false);
    });
    await waitFor(tester, () => ctl.live.transpose == 1, ms: 4000);
    expect(ctl.boardState!.transpose, greaterThan(0.5), reason: 'a semitone up, as the board says (31-TET: 1.161)');

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
    expect(ctl.status, startsWith('Virtual ·'));
    expect(ctl.playable, isTrue);
    expect(ctl.voices.length, ctl.virtual.instrument!.board.state.voices);
    // mono legato on the firmware itself: key 9 switches it, StcY reports it, the app reads it back
    expect(ctl.legato, isNotNull, reason: 'this firmware reports legato= in StcY');
    final was = ctl.legato!;
    expect(ctl.legatoSwitchable, isTrue);
    expect(await run(tester, ctl.toggleLegato()), isTrue);
    await waitFor(tester, () => ctl.legato == !was);
    expect(await run(tester, ctl.toggleLegato()), isTrue);
    await waitFor(tester, () => ctl.legato == was);
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
    expect(ctl.soundLine, contains('Virtual ·'));
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
    final sw = Stopwatch()..start();
    var firstUs = -1;
    final seenAt = c.onStream!;
    c.onStream = (src, id, v, n) {
      if (src == Src.midi && firstUs < 0) firstUs = sw.elapsedMicroseconds;
      seenAt(src, id, v, n);
    };
    expect(ctl.midi!.backend.inject('test controller', bytes), greaterThanOrEqualTo(0));
    await waitFor(tester, () => seen.length >= 6, ms: 4000);
    // measured: the bytes in, the firmware's monitor message back over its console (an upper bound
    // of when the firmware had them: it includes the console stream and the transport's 2 ms poll)
    // ignore: avoid_print
    print('MIDI in -> the firmware\u2019s monitor back in the app: ${(firstUs / 1000).toStringAsFixed(2)} ms');
    // [channel, status nibble, data 1, data 2]: running status expanded, the clock (F8) dropped
    expect(seen, [
      [1, 0x9, 60, 100],
      [1, 0xD, 80, 0],
      [1, 0xB, 74, 70],
      [1, 0xE, 0x00, 0x48],
      [1, 0xE, 74, 71],
      [1, 0x8, 60, 30],
    ]);
    // and a note plays: the firmware's MIDI note path gives a voice its pressure
    final vb = ctl.virtual.instrument!.board;
    expect(ctl.midi!.backend.inject('test controller', const [0xD1, 70, 0x91, 62, 90]), greaterThanOrEqualTo(0));
    await waitFor(tester, () => vb.state.controls.any((v) => v[1] > 0), ms: 4000);
    ctl.midi!.backend.inject('test controller', const [0x81, 62, 40]);
    await waitFor(tester, () => !vb.state.controls.any((v) => v[1] > 0), ms: 4000);
    // a MIDI 2.0 controller: its UMP words, untouched, into the firmware's MIDI 2.0 input
    expect(ctl.midi!.backend.injectUmp('test MIDI 2.0 controller', const [0x40D10000, 0x8CCCCCCC, 0x40913E00, 0xB0000000]), 2);
    await waitFor(tester, () => vb.state.controls.any((v) => v[1] > 0), ms: 4000);
    await waitFor(tester, () => ctl.midi!.status('test MIDI 2.0 controller') != null, ms: 3000); // the next refresh lists it
    expect(ctl.midi!.status('test MIDI 2.0 controller')!.midi2, isTrue, reason: 'the menu marks it MIDI 2.0');
    ctl.midi!.backend.injectUmp('test MIDI 2.0 controller', const [0x40813E00, 0x50000000]);
    await run(tester, ctl.userDisconnect());
    expect(ctl.midi!.running, isFalse);
    await finish(tester, ctl);
  });

  testWidgets('the virtual firmware switched at run time: torn down, the old library let go of, started on the new one; a bad file refused', skip: skip != null, (
    tester,
  ) async {
    final dir = await tester.runAsync(() async => Directory.systemTemp.createTempSync('sv_fw'));
    String copy(String name) {
      final d = Directory('${dir!.path}${Platform.pathSeparator}$name')..createSync();
      return File(lib!).copySync('${d.path}${Platform.pathSeparator}${lib.split(RegExp(r'[\\/]')).last}').path;
    }

    final a = copy('2026-10-01 build a'), b = copy('2026-10-24 build b');
    final ctl = AppController(options: AppOptions(virtualLib: a, noUsb: true), store: Store.memory());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    expect(ctl.firmwarePath, File(a).absolute.path);
    expect(await run(tester, ctl.useBuild(b)), isTrue);
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    expect(ctl.firmwarePath, File(b).absolute.path);
    expect(ctl.version!.line, startsWith(ctl.virtual.version!));
    expect(StrisoVirtualLib.isLoaded(a), isFalse, reason: 'the old build is unloaded');
    expect(ctl.store.get<String>('virtualLib'), File(b).absolute.path, reason: 'remembered');
    // not a library: refused, the problem names the build and offers another, Virtual stays down
    final junkDir = Directory('${dir!.path}${Platform.pathSeparator}junk build')..createSync();
    final junk = File('${junkDir.path}${Platform.pathSeparator}junk.dll')..writeAsStringSync('no');
    expect(await run(tester, ctl.useBuild(junk.path)), isFalse);
    expect(ctl.state, isA<Failed>());
    expect(ctl.problem, isNotNull);
    expect(ctl.problem!.actions, contains(Fix.pickBuild));
    expect(ctl.virtual.buildTitle, 'junk build');
    expect(ctl.buildList().where((x) => x.path == junk.absolute.path).single.loadable, isFalse);
    expect(ctl.store.get<String>('virtualLib'), File(b).absolute.path, reason: 'a build that did not play is not remembered');
    // and back to a good one, remembered as the one before it for the swap
    expect(await run(tester, ctl.useBuild(a)), isTrue);
    expect(ctl.previousBuild, File(b).absolute.path);
    expect(await run(tester, ctl.swapBuild()), isTrue);
    expect(ctl.firmwarePath, File(b).absolute.path);
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    await finish(tester, ctl);
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  testWidgets('a firmware release zip installed from the picker: checked, kept in the firmware folder, played', skip: skip != null, (tester) async {
    final dir = await tester.runAsync(() async => Directory.systemTemp.createTempSync('sv_install'));
    final bytes = File(lib!).readAsBytesSync();
    final name = lib.split(RegExp(r'[\\/]')).last;
    final top = 'striso_virtual-test-${virtualPlatform()}';
    final a = Archive()
      ..addFile(ArchiveFile.bytes('$top/$name', bytes))
      ..addFile(
        ArchiveFile.string(
          '$top/manifest.json',
          jsonEncode({
            'version': 'test build',
            'platform': virtualPlatform(),
            'library': name,
            'sha256': sha256.convert(bytes).toString(),
            'api_version': svApiVersion,
          }),
        ),
      );
    final zip = File('${dir!.path}${Platform.pathSeparator}$top.zip')..writeAsBytesSync(ZipEncoder().encode(a));
    final ctl = AppController(
      options: const AppOptions(noUsb: true),
      store: Store('${dir.path}${Platform.pathSeparator}settings.json'),
    );
    expect(await run(tester, ctl.installAndUseFirmware(zip.path)), isTrue, reason: ctl.banner?.text);
    expect(ctl.firmwarePath, startsWith('${dir.path}${Platform.pathSeparator}firmware${Platform.pathSeparator}test build'));
    expect(ctl.buildList().map((b) => b.build.name), contains('test build'));
    expect(ctl.buildList().where((b) => b.build.name == 'test build').single.current, isTrue);
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    await finish(tester, ctl);
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  // the engine slots on the real firmware (mod-modules: Stci, Stco, Stcz, sv_options
  // .module_store): a package with this PC's image put on Virtual from the library, Virtual started
  // again with it on its first voice, kept in the data folder's module store; a board-only
  // package refused with the firmware's words; erased. The packages come from the firmware's build
  // ($STRISO_PACKAGE_DIR, or its virtual/tests/packages; $STRISO_ARM_PACKAGE_DIR, build/firmware/
  // modules); skipped by a build without slots.
  String? pkg(String name, List<String> dirs) {
    for (final d in dirs) {
      final f = File('$d/$name.nsc');
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  final fw = Platform.environment['STRISO_FW_DIR'];
  final pcPkg = pkg('accordion', [
    ?Platform.environment['STRISO_PACKAGE_DIR'],
    if (fw != null) for (final b in ['host-virtual', 'host']) '$fw/build/$b/virtual/tests/packages',
    if (lib != null) '${File(lib).parent.path}/tests/packages',
  ]);
  final armPkg = pkg('sine', [?Platform.environment['STRISO_ARM_PACKAGE_DIR'], if (fw != null) '$fw/build/firmware/modules']);
  testWidgets(
    'engine slots on the real firmware: put on Virtual, its voices after a restart, a board-only package refused, erased',
    skip: skip != null || pcPkg == null,
    (tester) async {
      final dir = await tester.runAsync(() async => Directory.systemTemp.createTempSync('sv_slots'));
      final sep = Platform.pathSeparator;
      final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: lib), store: Store('${dir!.path}${sep}settings.json'));
      await run(tester, ctl.playVirtual());
      await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
      if (ctl.moduleSlots == null) {
        markTestSkipped('this build has no engine slots (Stco)');
        await finish(tester, ctl);
        return;
      }
      expect(ctl.moduleSlots!.map((s) => s.state).toSet(), {SlotState.empty});
      final own = ctl.voices.length;
      expect(await run(tester, ctl.installAndAddEngine(pcPkg!), seconds: 120, step: 5), isTrue, reason: ctl.moduleNote?.text);
      await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
      final slot = ctl.moduleSlots!.where((s) => s.holdsEngine).single;
      expect(slot.state, SlotState.ok);
      expect(ctl.voices.length, greaterThan(own), reason: 'listed after the built-in engines');
      expect(ctl.voices.skip(own).map((v) => v.engine).toSet(), {slot.id});
      expect(ctl.voiceName == slot.id || ctl.voiceName.startsWith('${slot.id}:'), isTrue, reason: 'its first voice (${ctl.voiceName})');
      expect(File('${dir.path}${sep}virtual${sep}module_store.bin').existsSync(), isTrue, reason: 'kept in the data folder');
      if (armPkg != null) {
        expect(await run(tester, ctl.installAndAddEngine(armPkg), seconds: 120, step: 5), isFalse);
        expect(ctl.moduleNote!.error, isTrue);
        expect(ctl.moduleNote!.text, startsWith('sine is not on Virtual: '));
      }
      expect(await run(tester, ctl.eraseSlot(slot.slot), seconds: 60, step: 5), isTrue, reason: ctl.moduleNote?.text);
      await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
      expect(ctl.voices.length, own);
      expect(ctl.moduleSlots!.where((s) => s.holdsEngine), isEmpty);
      await finish(tester, ctl);
      await tester.runAsync(() async {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // the board's sound presets on the real firmware (mod-presets, doc/presets_console.md): what
  // the app does with J, j, F, x and O, against a build that has them (the virtual board always
  // has the store); skipped by a build that does not answer StcJ
  testWidgets('presets on the real firmware: list, text, save as, install, load with the report, delete', skip: skip != null, (tester) async {
    final dir = await tester.runAsync(() async => Directory.systemTemp.createTempSync('sv_presets'));
    final sep = Platform.pathSeparator;
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: lib), store: Store('${dir!.path}${sep}settings.json'));
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    await waitFor(tester, () => ctl.boardPresets != null, ms: 2000).catchError((_) {});
    if (ctl.boardPresets == null) {
      markTestSkipped('this build does not answer StcJ');
      await finish(tester, ctl);
      return;
    }
    final c = ctl.client!;
    // J: the factory presets are the voice entries, in voice order; the store is there
    final list = ctl.boardPresets!;
    expect(list.storeOn, isTrue, reason: 'the virtual board always has the store');
    expect(list.presets.where((p) => p.factory).length, ctl.voices.length);
    for (final v in ctl.voices) {
      expect(ctl.factoryPresetOf(v.index)!.title, v.preset ?? v.engine, reason: 'entry ${v.index}');
      expect(ctl.factoryPresetOf(v.index)!.engine, v.engine);
    }
    expect(list.user, isEmpty);
    // j: a factory preset's file; strisy has none
    final pad = ctl.voices.firstWhere((v) => v.name == 'va:pad');
    final padText = await run(tester, ctl.presetFileText(ctl.factoryPresetOf(pad.index)!));
    expect(describePresetFile(padText!).title, 'pad');
    expect(describePresetFile(padText).engine, 'va');
    expect(describePresetFile(padText).preset, isTrue);
    final strisy = await run(tester, c.presetText(ctl.factoryPresetOf(ctl.voices.firstWhere((v) => v.engine == 'strisy').index)!.id));
    expect(strisy!.why, startsWith('no text '));
    expect(AppController.presetWhy(strisy.why), 'this voice has no preset text');
    // F kind 2: save as, with a title and a description; the board writes the preset
    await run(tester, ctl.selectVoice(pad.index));
    final saved = await run(tester, ctl.savePresetAs('Warm | pad', 'Slow, dark.'));
    expect(saved, isNotNull, reason: ctl.toasts.value.lastOrNull?.text);
    expect(saved!.title, 'Warm / pad', reason: 'a | in a title is listed as /');
    expect(saved.description, 'Slow, dark.');
    expect(saved.engine, 'va');
    final savedText = (await run(tester, ctl.presetFileText(saved)))!;
    expect(describePresetFile(savedText).title, 'Warm | pad', reason: 'the file keeps the title as given');
    expect(describePresetFile(savedText).description, 'Slow, dark.');
    // O: it loads exactly on this engine
    final o = await run(tester, ctl.openBoardPreset(saved));
    expect(o!.exact, isTrue);
    expect(ctl.openPreset?.id, saved.id);
    // F kind 1: a file from another version of va, stored as sent; O reports what it changed
    final file = jsonEncode({
      'format': 'awva-preset/1',
      'engine': {'id': 'va', 'version': 'v2.2.4-200', 'params_hash': '00000000'},
      'title': 'Older lead',
      'params': {'gain': 99, 'old_knob': 1},
    });
    final f = File('${dir.path}${sep}older.preset.json')..writeAsStringSync(file);
    final inst = await run(tester, ctl.installPresetFile(f.path));
    expect(inst, isNotNull, reason: ctl.toasts.value.lastOrNull?.text);
    expect((await run(tester, ctl.presetFileText(inst!))), file, reason: 'stored byte for byte');
    final rep = await run(tester, ctl.openBoardPreset(inst));
    expect(rep!.exact, isFalse);
    expect(rep.clampedNames, ['gain']);
    expect(rep.skippedNames, ['old_knob']);
    expect(rep.missing, greaterThan(0));
    expect(ctl.banner?.text, contains('gain'));
    expect(ctl.banner?.text, contains('old_knob'));
    await waitFor(tester, () => ctl.voices.where((v) => v.current).firstOrNull?.engine == 'va');
    // refusals, in words
    final junk = File('${dir.path}${sep}junk.json')..writeAsStringSync('{not json');
    expect(await run(tester, ctl.installPresetFile(junk.path)), isNull);
    expect(ctl.toasts.value.last.text, contains('not a preset file (syntax)'));
    final flute = File('${dir.path}${sep}flute.json')..writeAsStringSync(file.replaceAll('"va"', '"flute"'));
    expect(await run(tester, ctl.installPresetFile(flute.path)), isNull);
    expect(ctl.toasts.value.last.text, contains('its engine (flute) is not on this Striso'));
    expect(await run(tester, ctl.savePresetAs('x' * 64, '')), isNull, reason: 'refused before it is sent');
    final long = await run(tester, c.savePresetAs('x' * 64, ''));
    expect(long!.why, 'fields');
    // a byte above 0x80 is refused by the board too (the app refuses it before sending)
    final high = await run(tester, c.installPreset([...utf8.encode('{"title": "Caf'), 0xc3, 0xa9, ...utf8.encode('"}')]));
    expect(high!.why, 'not ascii 14');
    expect(AppController.presetWhy(high.why), contains('beyond plain ASCII (at byte 14)'));
    // x: delete; a factory preset stays
    expect(await run(tester, ctl.deleteBoardPreset(saved)), isTrue);
    expect(ctl.boardPresets!.user.map((p) => p.title), ['Older lead']);
    final again = await run(tester, c.deletePreset(saved.id));
    expect(again!.why, 'no preset ${saved.id}');
    final factory = await run(tester, c.deletePreset(ctl.factoryPresetOf(pad.index)!.id));
    expect(factory!.why, startsWith('factory '));
    expect(AppController.presetWhy(factory.why), 'factory presets stay');
    await finish(tester, ctl);
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  // the console's MIDI in toggle on the real firmware: StcM on, a controller's notes in the log
  // as the board reports them, Stcm off
  testWidgets('the MIDI monitor on the real firmware: what the board gets, in the console log', skip: noAudio, (tester) async {
    final ctl = virtualApp();
    await run(tester, ctl.start());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    await run(tester, ctl.setMidiMonitor(true));
    expect(ctl.midiMonitor, isTrue);
    expect(ctl.midi!.backend.inject('test controller', const [0x91, 60, 100, 0xB1, 74, 70, 0x81, 60, 30]), greaterThanOrEqualTo(0));
    bool logged(String t) => appLog.lines.any((l) => l.text == t);
    await waitFor(tester, () => logged('MIDI in · ch 1 · note off 60 velocity 30'), ms: 4000);
    expect(logged('MIDI in · ch 1 · note on 60 velocity 100'), isTrue);
    expect(logged('MIDI in · ch 1 · control 74 = 70'), isTrue);
    await run(tester, ctl.setMidiMonitor(false));
    final n = appLog.lines.where((l) => l.text.startsWith('MIDI in ·')).length;
    ctl.midi!.backend.inject('test controller', const [0x91, 62, 90]);
    await settle(tester, ms: 400);
    expect(appLog.lines.where((l) => l.text.startsWith('MIDI in ·')).length, n, reason: 'off: nothing more');
    await finish(tester, ctl);
  });

  // the settings dials from the app on the real firmware (StcT, mod-dials): the board's list, a
  // value clamped and answered, StcY after; skipped by a build without StcT
  testWidgets('the dials on the real firmware: the board\'s list, values set, clamped and read back', skip: skip != null, (tester) async {
    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: lib), store: Store.memory());
    await run(tester, ctl.playVirtual());
    await waitFor(tester, () => ctl.dot == Dot.demo && !ctl.listsLoading);
    await waitFor(tester, () => ctl.dials != null, ms: 2000).catchError((_) {});
    if (ctl.dials == null) {
      markTestSkipped('this build does not answer StcT');
      await finish(tester, ctl);
      return;
    }
    DialInfo d(String n) => ctl.dials!.firstWhere((x) => x.name == n);
    expect(ctl.dials!.map((x) => x.name), ['ch', 'voices', 'bend', 'vol', 'sustain', 'rate', 'fine']);
    expect(d('bend').values, [12.0, 24.0, 48.0, 96.0]);
    expect(await run(tester, ctl.setDial(d('vol'), 100)), 100);
    expect(ctl.boardState!.volume, 100);
    expect(await run(tester, ctl.setDial(d('vol'), 300)), 127);
    expect(await run(tester, ctl.setDial(d('bend'), 30)), 24);
    expect(ctl.boardState!.bend, 24);
    expect(await run(tester, ctl.setDial(d('sustain'), 0.5)), 0.5);
    expect(ctl.boardState!.sustain, 0.5);
    expect(await run(tester, ctl.setDial(d('fine'), 10)), 9.38);
    expect(ctl.boardState!.fineCents, 9.38);
    expect(await run(tester, ctl.setDial(d('rate'), 0)), 1);
    expect(await run(tester, ctl.setDial(d('voices'), 4)), 4);
    expect(ctl.boardState!.voices, 4);
    await finish(tester, ctl);
  });
}
