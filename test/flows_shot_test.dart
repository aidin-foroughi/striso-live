// Screenshots of the flows (docs/flows.md) on Virtual (the firmware's own code, striso_virtual),
// for a look at the real pixels:
//   flutter test test/flows_shot_test.dart --dart-define=SHOT=path/to/prefix
// writes prefix_start.png (nothing plays), prefix_problem.png (a problem with its fixes, in the
// banner and on the board), prefix_chooser.png (Play Virtual's build chooser), prefix_virtual.png
// (Virtual plays: the build row), prefix_builds.png (the build menu over a firmware folder of
// titled builds), prefix_stopped.png.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/main.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_live/src/store.dart';

import 'support/app1.dart';
import 'support/virtual.dart';

final width = const int.fromEnvironment('SHOT_W', defaultValue: 1600).toDouble();
final height = const int.fromEnvironment('SHOT_H', defaultValue: 1000).toDouble();

void main() {
  testWidgets('flow screenshots', skip: virtualSkip != null, (tester) async {
    if (shot.isEmpty) return;
    await loadShotFonts(tester);
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // a firmware folder of titled builds: Sax v1 is the striso_virtual these tests run, the others
    // fake bytes (they cannot load, which the menu shows)
    final dir = Directory.systemTemp.createTempSync('flows_shot');
    final sep = Platform.pathSeparator;
    final fw = Directory('${dir.path}${sep}firmware')..createSync();
    String build(String folder, {String? title, String? description, String? fwv, bool real = false}) {
      final d = Directory('${fw.path}$sep$folder')..createSync();
      final path = '${d.path}$sep${virtualLibName()}';
      if (real) {
        File(virtualLib!).copySync(path);
      } else {
        File(path).writeAsStringSync('bytes');
      }
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
      return path;
    }

    const saxFolder = '2026-10-24_audition sax v1 (56f7266)';
    final sax = build(
      saxFolder,
      title: 'Sax v1',
      description: 'Soprano, alto, tenor and baritone on the wind key; the wind engine on key 16 for comparison.',
      real: true,
    );
    build('2026-10-25_audition trumpet stage2-3 (409b011)', title: 'Trumpet stage 2-3', fwv: '2026-10-25_v2.2.4-315-g409b011_all');
    build('2026-10-24_audition flute v1 (bee9528)', title: 'Flute v1', fwv: '2026-10-25_v2.2.4-299-gbee9528_all');
    build('2026-10-25_v2.2.4-308-g3e05282_all');
    build('2026-10-24_audition trumpet stage2-1 (20a9151)');

    final ctl = AppController(options: AppOptions(noUsb: true, virtualLib: sax), store: Store('${dir.path}${sep}settings.json'));
    await tester.pumpWidget(RepaintBoundary(key: const Key('shot'), child: StrisoLiveApp(ctl)));

    Future<void> save(String name) async {
      await settle(tester, ms: 320);
      await savePng(tester, name);
    }

    await save('start');
    await tester.tap(find.byKey(const Key('mode-striso')));
    await save('problem');
    await tester.tap(find.byKey(const Key('fix-playVirtual')).first);
    await settle(tester, ms: 240);
    await save('chooser');
    await tester.tap(find.byKey(const Key('build-$saxFolder')));
    await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading);
    await save('virtual');
    await tester.tap(find.byKey(const Key('mode-virtual')));
    await save('builds');
    await tester.tapAt(const Offset(5, 5));
    await settle(tester, ms: 160);
    await tester.tap(find.byKey(const Key('btn-connect')));
    await settle(tester, ms: 400);
    await save('stopped');
    await finish(tester, ctl);
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {} // the build's library stays loaded until the process ends
    });
  });
}
