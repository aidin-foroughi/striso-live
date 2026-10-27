// Helpers of the widget and screenshot tests on Virtual (the firmware's own code, striso_virtual):
// the start screen's Play Virtual, keys played on the instrument, a settings key pressed on the
// instrument itself, the screenshots' fonts and PNGs. The shared ones are in virtual.dart.
import 'dart:io';
import 'dart:ui' as dui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';

import 'virtual.dart';

/// Virtual from the start screen's Play Virtual: the build chooser, the build chosen
/// ([virtualLib]); its lists read.
Future<void> tapPlayVirtual(WidgetTester tester, AppController ctl) async {
  await tester.tap(find.byKey(const Key('fix-playVirtual')).first);
  await settle(tester, ms: 300);
  final build = ctl.buildList().firstWhere((b) => b.current);
  await tester.tap(find.byKey(Key('build-${build.build.name}')));
  await waitFor(tester, () => ctl.dot == Dot.virtual && !ctl.listsLoading && ctl.params[3]!.params.isNotEmpty);
}

/// Keys [ids] held on Virtual's instrument (its own key input), as a player presses them.
void press(AppController ctl, Iterable<int> ids, {double pres = 0.5, double x = 0, double y = 0, double strike = 0}) {
  for (final id in ids) {
    ctl.playBoard!.press(id, pres: pres, x: x, y: y, strike: strike);
  }
}

void release(AppController ctl, Iterable<int> ids) {
  for (final id in ids) {
    ctl.playBoard!.release(id);
  }
}

/// Settings held and key [id] pressed on the instrument itself: the firmware switches, the app
/// learns of it as of any change on the board.
Future<void> settingsKeyOnBoard(WidgetTester tester, AppController ctl, int id) async {
  final pl = ctl.playBoard!;
  pl.control(Idc.alt, true);
  await settle(tester, ms: 60);
  pl.press(id, pres: 0.4);
  await settle(tester, ms: 60);
  pl.release(id);
  await settle(tester, ms: 30);
  pl.control(Idc.alt, false);
}

/// The screenshots' prefix (--dart-define=SHOT=path/to/prefix); empty: the shot tests do nothing.
const shot = String.fromEnvironment('SHOT');

Future<void> _loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

/// The app's font, and from the system: Georgia, the Material icons of the Flutter SDK (tests have
/// no icon font otherwise), Segoe UI Symbol, a monospace one.
Future<void> loadShotFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    // flutter_tester runs from <flutter>/bin/cache/artifacts/engine/<platform>/
    final cache = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _loadFont('Inter', ['${Directory.current.path}/assets/fonts/Inter.ttf']);
    await _loadFont('Georgia', ['C:/Windows/Fonts/georgia.ttf']);
    await _loadFont('MaterialIcons', ['$cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    await _loadFont('Segoe UI Symbol', [r'C:\Windows\Fonts\seguisym.ttf']);
    await _loadFont('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
  });
}

/// The RepaintBoundary keyed 'shot' into [shot]_[name].png.
Future<void> savePng(WidgetTester tester, String name) async {
  final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
  final png = await tester.runAsync(() async {
    final img = await ro.toImage(pixelRatio: 1);
    final d = await img.toByteData(format: dui.ImageByteFormat.png);
    return d!.buffer.asUint8List();
  });
  File('${shot}_$name.png').writeAsBytesSync(png!);
}
