// Engines in the board's slots (research/board_engine_modules.md 4.3) on the Dart mock: the
// engine library of packages, Install… and Add an engine… taking a package or a zip of them, the
// Setup column's slot list as the firmware gives it (Stco), a package put on Virtual with the
// firmware's progress (Stci) and Virtual started again with it on its first voice, a package for
// another engine ABI listed disabled with the firmware's reason, and an erase (Stcz). The mock
// answers in the firmware's form (MockModuleStore, mockModulePackage).
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/engine_library.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';

import 'flows_test.dart' show boot, finish, pumpUntil, settle, untilLive;

final sep = Platform.pathSeparator;

/// A mock package file `<name>.nsc` (the mock reads its id; a real one is the firmware's to read).
String package(Directory d, String name, {String? id, String version = '1.0', int abi = mockEngineAbi, int padTo = 9000}) {
  d.createSync(recursive: true);
  return (File('${d.path}$sep$name.nsc')..writeAsBytesSync(mockModulePackage(id ?? name, version: version, abi: abi, padTo: padTo))).path;
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
    expect(installEngine(sax, out), ['$out${sep}sax.nsc']);
    final zip = Archive()
      ..addFile(ArchiveFile('pkgs/clarinet.nsc', 4, [1, 2, 3, 4]))
      ..addFile(ArchiveFile('pkgs/sine.nsc', 2, [5, 6]))
      ..addFile(ArchiveFile.string('pkgs/readme.txt', 'not a package'));
    final zf = File('${tmp.path}${sep}engines.zip')..writeAsBytesSync(ZipEncoder().encode(zip));
    expect(isEngineSource(zf.path), isTrue);
    expect(installEngine(zf.path, out), hasLength(2));
    expect(findEngines(out).map((e) => e.name), ['clarinet', 'sax', 'sine']);
    File(sax).writeAsBytesSync([9, 9]);
    installEngine(sax, out);
    expect(findEngines(out), hasLength(3), reason: 'replaced, not added');
    expect(File('$out${sep}sax.nsc').readAsBytesSync(), [9, 9]);
    final bare = File('${tmp.path}${sep}bare.zip')..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('x.dll', 1, [1]))));
    expect(isEngineSource(bare.path), isFalse);
    expect(() => installEngine(bare.path, out), throwsA(isA<FirmwareInstallError>().having((e) => '$e', 'why', contains('no engine package'))));
    expect(() => installEngine('${tmp.path}${sep}sax.dll', out), throwsA(isA<FirmwareInstallError>()));
    expect(isEngineSource('${tmp.path}$sep${virtualLibName()}'), isFalse);
    final rel = File('${tmp.path}${sep}striso_virtual-v2.zip')
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile.string('striso_virtual/manifest.json', '{}'))));
    expect(isEngineSource(rel.path), isFalse);
  });

  testWidgets('Setup: the slots of Virtual; an engine put on it plays; another ABI disabled with the reason; erased', (tester) async {
    final dir = Directory.systemTemp.createTempSync('flows_engines');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final built = Directory('${dir.path}${sep}built');
    final sax = package(built, 'sax', version: '0.3');
    final clarinet = package(built, 'clarinet', abi: 9);
    final ctl = AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store('${dir.path}${sep}settings.json'));
    expect(ctl.engineDir, '${dir.path}${sep}engines');
    await boot(tester, ctl);
    await pumpUntil(tester, ctl.playVirtual());
    await untilLive(tester, ctl);
    final own = ctl.voices.length;
    expect(ctl.moduleSlots, [for (var k = 2; k <= 6; k++) ModuleSlot(k, SlotState.empty)]);
    ctl.setTab(AppTab.setup);
    await settle(tester, 300);
    expect(find.text('Engines on Virtual'.toUpperCase()), findsOneWidget);
    expect(find.byKey(const Key('slot-2')), findsOneWidget);
    expect(find.byKey(const Key('slots-add')), findsOneWidget);

    // Add an engine… (the dialog's result): into the library, onto Virtual, which starts again
    // with it on its first voice
    final ups = <int>[];
    void seen() => ups.add(ctl.moduleUpload.value?.bytes ?? -1);
    ctl.moduleUpload.addListener(seen);
    expect(await pumpUntil(tester, ctl.installAndAddEngine(sax)), isTrue, reason: ctl.moduleNote?.text);
    ctl.moduleUpload.removeListener(seen);
    await untilLive(tester, ctl);
    await settle(tester, 300);
    expect(ups, containsAllInOrder([0, 4096, 8192, 9000]), reason: 'the firmware’s progress');
    expect(ctl.engineLibrary().map((p) => p.name), ['sax']);
    expect(ctl.moduleSlots!.first, const ModuleSlot(2, SlotState.ok, id: 'sax', version: '0.3', abi: mockEngineAbi, bytes: 9000));
    expect(ctl.voices.length, own + 4);
    expect(ctl.voiceName, 'sax:soprano sax');
    expect(ctl.moduleNote?.text, 'sax 0.3 is in slot 2; Virtual started again with it');
    expect(find.text('sax 0.3'), findsOneWidget);
    expect(find.byKey(const Key('put-sax')), findsOneWidget, reason: 'the library, to put it on again');

    // another engine ABI: kept in a slot, disabled with the firmware's words
    expect(await pumpUntil(tester, ctl.installAndAddEngine(clarinet)), isTrue);
    await untilLive(tester, ctl);
    await settle(tester, 300);
    expect(ctl.moduleSlots![1].state, SlotState.disabled);
    expect(find.text('disabled: abi 9, firmware has $mockEngineAbi'), findsOneWidget);
    expect(ctl.voices.length, own + 4, reason: 'a disabled one gives no voices');

    // what the firmware refuses: its reason, nothing restarts
    final junk = File('${built.path}${sep}junk.nsc')..writeAsBytesSync([1, 2, 3]);
    expect(await pumpUntil(tester, ctl.installAndAddEngine(junk.path)), isFalse);
    await settle(tester, 300);
    expect(ctl.moduleNote, (text: 'junk is not on Virtual: not a package the mock reads', error: true));
    expect(find.byKey(const Key('slots-note')), findsOneWidget);

    // erase slot 2 (confirmed): Virtual starts again without the sax
    await tester.ensureVisible(find.byKey(const Key('erase-2')));
    await settle(tester, 200);
    await tester.tap(find.byKey(const Key('erase-2')));
    await settle(tester, 300);
    expect(find.text('Erase slot 2?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dlg-erase-go')));
    for (var i = 0; i < 60 && ctl.voices.length != own; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 100);
    }
    await untilLive(tester, ctl);
    expect(ctl.voices.length, own);
    expect(ctl.moduleSlots!.first.state, SlotState.empty);
    expect(ctl.moduleNote?.text, 'Slot 2 erased (sax); Virtual started again without it');
    await finish(tester, ctl);
  });
}
