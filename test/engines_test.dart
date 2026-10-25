// Engines as sounds (docs/flows.md 10) on the Dart mock: the engine folder and its manifests,
// Install… taking an engine (zip or library), the ENGINES TO ADD rows of the build chooser, a tick
// starting Virtual again with the engine (its first voice, its colour as Stce gives it), ⇄ between
// with and without it (each on its own voice), and an engine the firmware refused greyed with the
// firmware's reason and unticked. The mock answers Stce in the firmware's form (MockComponent).
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

import 'flows_test.dart' show boot, finish, pumpUntil, settle, untilLive;

final sep = Platform.pathSeparator;

Map<String, Object?> manifestOf(String id, {int abi = 1, List<String> presets = const [], String? summary}) => {
  'id': id,
  'uid': 'com.sorbet-ai.awva.$id',
  'name': id,
  'summary': ?summary,
  'abi': abi,
  'version': '0a00222',
  'presets': presets,
};

/// An awva build's output for one engine: `<id>.<ext>` (fake bytes; the mock loads by name) and
/// `<id>.json`.
String component(Directory d, String id, {int abi = 1, List<String> presets = const [], String? summary}) {
  d.createSync(recursive: true);
  final lib = File('${d.path}$sep$id.${engineExt()}')..writeAsStringSync('engine $id');
  File('${d.path}$sep$id.json').writeAsStringSync(jsonEncode(manifestOf(id, abi: abi, presets: presets, summary: summary)));
  return lib.path;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('engines'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the manifest the awva build writes names an engine; anything else names nothing', () {
    final m = EngineManifest.tryParse(jsonEncode(manifestOf('sax', presets: ['soprano sax', 'alto sax'], summary: 'physical saxophones')))!;
    expect(m.id, 'sax');
    expect(m.abi, 1);
    expect(m.summary, 'physical saxophones');
    expect(m.presets, hasLength(2));
    expect(EngineManifest.tryParse('{not json'), isNull);
    expect(EngineManifest.tryParse(jsonEncode({'name': 'no id'})), isNull);
    final c = engineOf(component(Directory('${tmp.path}${sep}build'), 'sax', presets: ['a', 'b', 'c', 'd']));
    expect(c.title, 'sax');
    expect(c.facts, '0a00222 · 4 presets');
  });

  test('install: a library with its manifest, a zip, the same engine replaced; a build is not an engine', () async {
    final out = '${tmp.path}${sep}engines';
    final built = Directory('${tmp.path}${sep}awva${sep}build${sep}sdk${sep}components');
    final sax = component(built, 'sax', presets: ['soprano sax']);
    expect(isEngineSource(sax), isTrue);
    final lib = await installEngine(sax, out, run: (_, _) async => ProcessResult(0, 0, '', ''));
    expect(lib, '$out${sep}sax${sep}sax.${engineExt()}');
    expect(File('$out${sep}sax${sep}sax.json').existsSync(), isTrue, reason: 'its manifest came along');
    // a zip of the two files (in a folder)
    final zip = Archive()
      ..addFile(ArchiveFile('clarinet/clarinet.${engineExt()}', 6, utf8.encode('engine')))
      ..addFile(ArchiveFile.string('clarinet/clarinet.json', jsonEncode(manifestOf('clarinet', presets: ['clarinet', 'bass clarinet']))));
    final zf = File('${tmp.path}${sep}clarinet-engine.zip')..writeAsBytesSync(ZipEncoder().encode(zip));
    expect(isEngineSource(zf.path), isTrue);
    await installEngine(zf.path, out, run: (_, _) async => ProcessResult(0, 0, '', ''));
    expect(findEngines(out).map((e) => e.title), ['clarinet', 'sax']);
    // installed again: replaced, not added
    File(sax).writeAsStringSync('engine sax, rebuilt');
    await installEngine(sax, out, run: (_, _) async => ProcessResult(0, 0, '', ''));
    expect(findEngines(out), hasLength(2));
    expect(File(lib).readAsStringSync(), 'engine sax, rebuilt');
    // a zip without the manifest is refused with why
    final bare = File('${tmp.path}${sep}bare.zip')..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('x.${engineExt()}', 1, [1]))));
    expect(() => installEngine(bare.path, out), throwsA(isA<FirmwareInstallError>().having((e) => '$e', 'why', contains('x.json'))));
    // a firmware build is not an engine
    expect(isEngineSource('${tmp.path}$sep${virtualLibName()}'), isFalse);
    final rel = File('${tmp.path}${sep}striso_virtual-v2.zip')
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile.string('striso_virtual/manifest.json', '{}'))));
    expect(isEngineSource(rel.path), isFalse);
  });

  test('staging: a fresh folder per run in the list order, the old one removed', () {
    final out = '${tmp.path}${sep}engines';
    final a = engineOf(component(Directory('$out${sep}sax'), 'sax'));
    final b = engineOf(component(Directory('$out${sep}clarinet'), 'clarinet'));
    final one = stageEngines([a, b], out)!;
    expect(one.files.keys.toSet(), {'sax.${engineExt()}', 'clarinet.${engineExt()}'});
    expect(one.files['sax.${engineExt()}'], a.path);
    final two = stageEngines([a], out)!;
    expect(Directory(one.dir).existsSync(), isFalse);
    expect(Directory(two.dir).listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last), ['sax.${engineExt()}']);
    expect(findEngines(out), hasLength(2), reason: 'the staging folder is not an engine');
    expect(stageEngines([], out), isNull);
  });

  testWidgets('the chooser: tick an engine, it plays; ⇄ with and without it; a refused one greyed with the reason', (tester) async {
    final dir = Directory.systemTemp.createTempSync('flows_engines');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final engines = '${dir.path}${sep}engines';
    component(Directory('$engines${sep}sax'), 'sax', presets: ['soprano sax', 'alto sax', 'tenor sax', 'baritone sax'], summary: 'physical saxophones');
    component(Directory('$engines${sep}flute'), 'flute', abi: 1, summary: 'a flute for the next engine ABI');
    final ctl = AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store('${dir.path}${sep}settings.json'));
    expect(ctl.engineDir, engines);
    await boot(tester, ctl);
    await pumpUntil(tester, ctl.playVirtual());
    await untilLive(tester, ctl);
    final own = ctl.voices.length;
    expect(ctl.engineReport?.abi, mockEngineAbi, reason: 'asked once there are engines to add');
    expect(ctl.engineReport!.loaded, isEmpty);

    // the chooser: the engines under the builds, none ticked
    await tester.tap(find.byKey(const Key('mode-virtual')));
    await settle(tester, 400);
    expect(find.text('ENGINES TO ADD'), findsOneWidget);
    expect(find.text('physical saxophones'), findsOneWidget);
    expect(find.byKey(const Key('engine-sax-off')), findsOneWidget);
    expect(find.text('Install a build or an engine…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('engine-sax')));
    await settle(tester, 200);
    for (var i = 0; i < 60 && (ctl.engineReport?.loaded.isEmpty ?? true); i++) {
      await settle(tester, 100);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await untilLive(tester, ctl);
    await pumpUntil(tester, Future<void>.delayed(Duration.zero));
    for (var i = 0; i < 40 && ctl.voiceName != 'sax:soprano sax'; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 100);
    }
    // it plays: its voices after the build's own, its first one chosen, in the firmware's colour
    expect(ctl.voices.length, own + 4);
    expect(ctl.voices.skip(own).map((v) => v.name).first, 'sax:soprano sax');
    expect(ctl.voiceName, 'sax:soprano sax', reason: 'the added engine\'s first voice, once');
    expect(ctl.engines().firstWhere((e) => e.engine == 'sax').color, 0xc08040, reason: 'Stce\'s colour');
    expect(ctl.engineList().firstWhere((e) => e.title == 'sax').ticked, isTrue);
    expect(ctl.engineList().firstWhere((e) => e.title == 'sax').loaded?.count, 4);
    expect(ctl.swapTitle, 'without sax');
    expect(find.byKey(const Key('build-swap')), findsOneWidget);

    // ⇄: without it, on the voice that played before; and back, on the sax
    final before = ctl.previousSetup!.voice;
    await pumpUntil(tester, ctl.swapBuild());
    await untilLive(tester, ctl);
    expect(ctl.voices.length, own);
    expect(ctl.voiceName, before);
    expect(ctl.swapTitle, 'with sax');
    await pumpUntil(tester, ctl.swapBuild());
    await untilLive(tester, ctl);
    expect(ctl.voices.length, own + 4);
    expect(ctl.voiceName, 'sax:soprano sax');

    // the flute: the firmware refuses it (another engine ABI); greyed with its reason, unticked
    await pumpUntil(tester, ctl.toggleEngine(ctl.engineList().firstWhere((e) => e.title == 'flute').path));
    await untilLive(tester, ctl);
    final flute = ctl.engineList().firstWhere((e) => e.title == 'flute');
    expect(flute.reason, 'built for engine ABI 2; this build loads 1');
    expect(flute.ticked, isFalse);
    expect(flute.choosable, isFalse);
    expect(ctl.enginesFor(''), hasLength(1), reason: 'the sax stays; the refused flute is not kept');
    await tester.tap(find.byKey(const Key('mode-virtual')));
    await settle(tester, 400);
    expect(find.text('built for engine ABI 2; this build loads 1'), findsWidgets);
    expect(tester.widget<PopupMenuItem<String>>(find.byKey(const Key('engine-flute'))).enabled, isFalse);
    await tester.tapAt(const Offset(5, 1000)); // close the menu
    await settle(tester, 300);

    // remembered: the next run of the app plays the sax with the build again
    await finish(tester, ctl);
    final again = AppController(options: const AppOptions(noUsb: true, mockDemo: true), store: Store('${dir.path}${sep}settings.json'));
    expect(again.enginesFor(''), hasLength(1));
    again.dispose();
  });
}
