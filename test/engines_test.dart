// Engines in the board's slots (research/board_engine_modules.md 4.3): the engine library of
// packages, Install… and Add an engine… taking a package or a zip of them; on Virtual (the real
// firmware's mod-modules) the Setup column's slot list as the firmware gives it (Stco), a real
// package put on Virtual with the firmware's progress (Stci) and Virtual started again with it on
// its first voice, a slot whose module faulted listed disabled with the firmware's reason, a file
// the firmware refuses, and an erase (Stcz). The package is the firmware build's own test package
// (the accordion, with its .json); skipped without it.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/engine_library.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';

import 'support/app2.dart';
import 'support/virtual.dart';

final sep = Platform.pathSeparator;

/// A file `<name>.awvapkg` with [bytes] (the library reads names, not contents).
String package(Directory d, String name, [List<int> bytes = const [1, 2, 3, 4]]) {
  d.createSync(recursive: true);
  return (File('${d.path}$sep$name.awvapkg')..writeAsBytesSync(bytes)).path;
}

/// The firmware build's accordion package (virtual/tests/packages, next to the library), or null.
String? accordionPackage() {
  final lib = virtualLib;
  if (lib == null) return null;
  final f = File('${File(lib).parent.path}${sep}tests${sep}packages${sep}accordion.awvapkg');
  return f.existsSync() && File(f.path.replaceFirst(RegExp(r'\.awvapkg$'), '.json')).existsSync() ? f.path : null;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('engines'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the library: a package, a zip of them, the same name replaced; a build is not an engine', () {
    final out = '${tmp.path}${sep}engines';
    final sax = package(Directory('${tmp.path}${sep}built'), 'sax');
    expect(isEngineSource(sax), isTrue);
    expect(installEngine(sax, out), ['$out${sep}sax.awvapkg']);
    final zip = Archive()
      ..addFile(ArchiveFile('pkgs/clarinet.awvapkg', 4, [1, 2, 3, 4]))
      ..addFile(ArchiveFile('pkgs/sine.awvapkg', 2, [5, 6]))
      ..addFile(ArchiveFile.string('pkgs/readme.txt', 'not a package'));
    final zf = File('${tmp.path}${sep}engines.zip')..writeAsBytesSync(ZipEncoder().encode(zip));
    expect(isEngineSource(zf.path), isTrue);
    expect(installEngine(zf.path, out), hasLength(2));
    expect(findEngines(out).map((e) => e.name), ['clarinet', 'sax', 'sine']);
    File(sax).writeAsBytesSync([9, 9]);
    installEngine(sax, out);
    expect(findEngines(out), hasLength(3), reason: 'replaced, not added');
    expect(File('$out${sep}sax.awvapkg').readAsBytesSync(), [9, 9]);
    final bare = File('${tmp.path}${sep}bare.zip')..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('x.dll', 1, [1]))));
    expect(isEngineSource(bare.path), isFalse);
    expect(() => installEngine(bare.path, out), throwsA(isA<FirmwareInstallError>().having((e) => '$e', 'why', contains('no engine package'))));
    expect(() => installEngine('${tmp.path}${sep}sax.dll', out), throwsA(isA<FirmwareInstallError>()));
    expect(isEngineSource('${tmp.path}$sep${virtualLibName()}'), isFalse);
    final rel = File('${tmp.path}${sep}striso_virtual-v2.zip')
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile.string('striso_virtual/manifest.json', '{}'))));
    expect(isEngineSource(rel.path), isFalse);
  });

  final accordion = accordionPackage();
  testWidgets(
    'Setup: the slots of Virtual; an engine put on it plays; a faulted one disabled with the reason; a refused file; erased',
    skip: virtualSkip != null || accordion == null,
    (tester) async {
      final dir = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('flows_engines')))!;
      // what the package is, as its build describes it
      final meta = jsonDecode(File(accordion!.replaceFirst(RegExp(r'\.awvapkg$'), '.json')).readAsStringSync()) as Map<String, Object?>;
      final version = meta['version'] as String, abi = meta['abi'] as int;
      final presets = (meta['presets'] as List).cast<String>();
      final size = File(accordion).lengthSync();
      final ctl = await bootApp(tester, store: Store('${dir.path}${sep}settings.json'));
      expect(ctl.engineDir, '${dir.path}${sep}engines');
      await playVirtual(tester, ctl);
      final own = ctl.voices.length;
      expect(ctl.moduleSlots, [for (var k = 2; k <= 6; k++) ModuleSlot(k, SlotState.empty)], reason: 'the firmware’s five slots, empty');
      ctl.setTab(AppTab.setup);
      await settle(tester, ms: 300);
      expect(find.text('Engines on Virtual'.toUpperCase()), findsOneWidget);
      expect(find.byKey(const Key('slot-2')), findsOneWidget);
      expect(find.byKey(const Key('slots-add')), findsOneWidget);

      // Add an engine… (the dialog's result): into the library, onto Virtual, which starts again
      // with it on its first voice
      final ups = <int>[];
      void seen() => ups.add(ctl.moduleUpload.value?.bytes ?? -1);
      ctl.moduleUpload.addListener(seen);
      expect(await run(tester, ctl.installAndAddEngine(accordion), seconds: 120, step: 5), isTrue, reason: ctl.moduleNote?.text);
      ctl.moduleUpload.removeListener(seen);
      await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
      await settle(tester, ms: 300);
      final progress = ups.where((u) => u >= 0).toList();
      expect(progress, [for (var n = 0; n < size; n += 4096) n, size], reason: 'the firmware’s progress, a piece at a time');
      expect(ctl.engineLibrary().map((p) => p.name), ['accordion']);
      final slot = ctl.moduleSlots!.first;
      expect((slot.slot, slot.state, slot.id, slot.version, slot.abi), (2, SlotState.ok, 'accordion', version, abi));
      expect(slot.bytes, greaterThan(0));
      expect(ctl.voices.skip(own).map((v) => v.name), [for (final p in presets) 'accordion:$p'], reason: 'its presets, after the built-in voices');
      expect(ctl.voiceName, 'accordion:${presets.first}');
      expect(ctl.moduleNote?.text, 'accordion $version is in slot 2; Virtual started again with it');
      expect(find.text('accordion $version'), findsOneWidget);
      expect(find.byKey(const Key('put-accordion')), findsOneWidget, reason: 'the library, to put it on again');

      // the board faulted in the module (the firmware's fault record): its slot kept, disabled with
      // the firmware's words, and no voices of it once Virtual starts again
      await tester.runAsync(() async => expect(ctl.virtual.instrument!.board.testHook(svTestModuleFault, 2), 0));
      expect(await run(tester, ctl.useBuild(ctl.virtual.libPath!)), isTrue);
      await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
      await settle(tester, ms: 300);
      final faulted = ctl.moduleSlots!.first;
      expect((faulted.state, faulted.id), (SlotState.disabled, 'accordion'));
      expect(faulted.reason, 'faulted (pc 0x00001234, cfsr 0x00005678)', reason: 'the fault the hook records');
      expect(find.text('disabled: ${faulted.reason}'), findsOneWidget);
      expect(ctl.voices.length, own, reason: 'a disabled one gives no voices');

      // what the firmware refuses: its reason, nothing restarts
      final junk = package(Directory('${dir.path}${sep}built'), 'junk');
      expect(await run(tester, ctl.installAndAddEngine(junk), seconds: 60, step: 5), isFalse);
      await settle(tester, ms: 300);
      expect(ctl.moduleNote!.error, isTrue);
      expect(ctl.moduleNote!.text, 'junk is not on Virtual: not a package (short)');
      expect(find.byKey(const Key('slots-note')), findsOneWidget);
      expect(ctl.moduleSlots!.where((s) => s.holdsEngine).map((s) => s.id), ['accordion'], reason: 'nothing put on');

      // erase slot 2 (confirmed): Virtual starts again without the accordion
      await tester.ensureVisible(find.byKey(const Key('erase-2')));
      await settle(tester, ms: 200);
      await tester.tap(find.byKey(const Key('erase-2')));
      await settle(tester, ms: 300);
      expect(find.text('Erase slot 2?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dlg-erase-go')));
      await waitFor(tester, () => ctl.moduleNote?.text.startsWith('Slot 2 erased') == true, ms: 20000, step: 5);
      await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
      expect(ctl.voices.length, own);
      expect(ctl.moduleSlots!.first.state, SlotState.empty);
      expect(ctl.moduleNote?.text, 'Slot 2 erased (accordion); Virtual started again without it');
      await finish(tester, ctl);
      await tester.runAsync(() async {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
