// Screenshots of the flows (docs/flows.md) on the Dart mock, for a look at the real pixels:
//   flutter test test/flows_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_start.png (nothing plays), prefix_problem.png (a problem with its fixes, in the
// banner and on the board), prefix_virtual.png (Virtual plays: the build row), prefix_builds.png
// (the build menu over a firmware folder of titled builds), prefix_stopped.png.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';

const shot = String.fromEnvironment('SHOT');
final width = const int.fromEnvironment('SHOT_W', defaultValue: 1600).toDouble();
final height = const int.fromEnvironment('SHOT_H', defaultValue: 1000).toDouble();

String _materialIcons() {
  final cache = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  return '$cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

Future<void> loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('flow screenshots', (tester) async {
    if (shot.isEmpty) return;
    await tester.runAsync(() async {
      await loadFont('Inter', ['${Directory.current.path}/assets/fonts/Inter.ttf']);
      await loadFont('Georgia', ['C:/Windows/Fonts/georgia.ttf']);
      await loadFont('MaterialIcons', [_materialIcons()]);
      await loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
      await loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
    });
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // a firmware folder of titled builds (fake bytes: they cannot load, which the menu shows)
    final dir = Directory.systemTemp.createTempSync('flows_shot');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final sep = Platform.pathSeparator;
    final fw = Directory('${dir.path}${sep}firmware')..createSync();
    String build(String folder, {String? title, String? description, String? fwv}) {
      final d = Directory('${fw.path}$sep$folder')..createSync();
      final lib = File('${d.path}$sep${virtualLibName()}')..writeAsStringSync('bytes');
      if (title != null) {
        File('${d.path}${sep}manifest.json').writeAsStringSync(
          jsonEncode({
            'name': 'striso_virtual',
            'version': folder,
            'platform': virtualPlatform(),
            'library': virtualLibName(),
            'sha256': '00',
            'api_version': 2,
            'firmware_version': fwv ?? '2026-10-25_v2.2.4-299-g56f7266_all',
            'title': title,
            'description': ?description,
          }),
        );
      }
      return lib.path;
    }

    final sax = build(
      '2026-10-24_audition sax v1 (56f7266)',
      title: 'Sax v1',
      description: 'Soprano, alto, tenor and baritone on the wind key; the wind engine on key 16 for comparison.',
    );
    build('2026-10-25_audition trumpet stage2-3 (409b011)', title: 'Trumpet stage 2-3', fwv: '2026-10-25_v2.2.4-315-g409b011_all');
    build('2026-10-24_audition flute v1 (bee9528)', title: 'Flute v1', fwv: '2026-10-25_v2.2.4-299-gbee9528_all');
    build('2026-10-25_v2.2.4-308-g3e05282_all');
    build('2026-10-24_audition trumpet stage2-1 (20a9151)');

    final ctl = AppController(
      options: AppOptions(noUsb: true, mockDemo: true, virtualLib: sax),
      store: Store('${dir.path}${sep}settings.json'),
    );
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));

    Future<void> run(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Future<void> save(String name) async {
      await run(8);
      final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final png = await tester.runAsync(() async {
        final img = await ro.toImage();
        final d = await img.toByteData(format: dui.ImageByteFormat.png);
        return d?.buffer.asUint8List();
      });
      File('${shot}_$name.png').writeAsBytesSync(png!);
    }

    await save('start');
    await tester.tap(find.byKey(const Key('mode-striso')));
    await save('problem');
    await tester.tap(find.byKey(const Key('fix-playVirtual')).first);
    for (var i = 0; i < 60 && (ctl.listsLoading || ctl.dot != Dot.demo); i++) {
      await run(2);
    }
    await save('virtual');
    await tester.tap(find.byKey(const Key('build-menu')));
    await save('builds');
    await tester.tapAt(const Offset(5, 5));
    await run(4);
    await tester.tap(find.byKey(const Key('btn-connect')));
    await run(10);
    await save('stopped');
    await ctl.endSession();
    await run(10);
    await tester.pumpWidget(const SizedBox());
    ctl.dispose();
  });
}
