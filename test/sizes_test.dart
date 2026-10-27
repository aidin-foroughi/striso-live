// Every screen at three window sizes (the design's 1480+ layout, the 1280 one and the minimum
// 1000x700), on the virtual board as the USB Striso: no overflow, no exception from any panel,
// and after the cable is pulled and the board comes back nothing stale stays on screen (the
// pending bar of a voice row, the hover readout, a key selected in the key equalizer).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/ui/knobs.dart';
import 'package:striso_live/src/ui/play_tab.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'support/app2.dart';
import 'support/virtual.dart';

const sizes = [Size(1000, 700), Size(1280, 800), Size(1600, 1000)];

void main() {
  final skip = virtualSkip != null;

  for (final size in sizes) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}: every tab, mode and overlay, then unplug and back', skip: skip, (tester) async {
      final b = await startBoard(tester);
      final usb = VirtualUsb(b);
      final hand = VirtualPlayer(b); // keys played on the instrument itself
      final store = Store.memory()..set('usbIntent', 'connected');
      final ctl = await bootApp(tester, usb: usb, store: store, size: size);
      // the error report (it names the widget) rather than the bare exception
      String report = '';
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) {
        report = d.toString();
        prevOnError?.call(d);
      };
      addTearDown(() => FlutterError.onError = prevOnError);
      Future<void> clean(String where) async {
        await settle(tester, ms: 300);
        final e = tester.takeException();
        expect(e, isNull, reason: '$where at ${size.width.toInt()}x${size.height.toInt()}: $report');
      }

      await clean('start screen');
      await run(tester, ctl.start());
      await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty, ms: 15000);
      ctl.setKey(root: 0, scale: 'major');
      await clean('Play, connected');

      // a chord held and released: the harmony strip with a numeral, the progression and a key
      const chord = [25, 29, 32];
      for (final id in chord) {
        hand.press(id, pres: 0.6, strike: 0.5);
      }
      await settle(tester, ms: 400);
      hand.releaseAll();
      await settle(tester, ms: 200);
      for (final id in [27, 31, 34]) {
        hand.press(id, pres: 0.5);
      }
      await clean('Play, a chord');
      hand.releaseAll();

      // the voice browser: another engine, its presets listed
      await tester.tap(find.byKey(const Key('engine-modal')));
      await waitFor(tester, () => ctl.voiceName.startsWith('modal:') && !ctl.listsLoading);
      await clean('Play, modal');

      await tester.tap(find.byKey(const Key('tab-sound')));
      await clean('Sound');
      ctl.setMorphOpen(true);
      await clean('Sound, morph open');
      ctl.setMorphOpen(false);

      await tester.tap(find.byKey(const Key('tab-setup')));
      await clean('Setup, sensitivity');
      await tester.tap(find.byKey(const Key('eq-on')));
      await settle(tester, ms: 100);
      ctl.eqSelect(27);
      await clean('Setup, key equalizer');
      await tester.tap(find.byKey(const Key('btn-settings-overlay')));
      await settle(tester, ms: 100);
      ctl.settingsClick(24);
      await clean('Setup, settings keys');
      await tester.tap(find.byKey(const Key('mode-sensitivity')));

      await tester.tap(find.byKey(const Key('tab-play')));
      await settle(tester, ms: 200);
      ctl.setStage(true);
      await clean('stage');
      ctl.setStage(false);
      await settle(tester, ms: 400);
      ctl.setConsole(true);
      await clean('console open');
      ctl.setConsole(false);
      ctl.setShortcuts(true);
      await clean('shortcut overlay');
      ctl.setShortcuts(false);

      // the cable pulled: the start screen's invite, nothing of the board left on screen
      ctl.hover = 25;
      await unplug(tester, usb);
      await waitFor(tester, () => !ctl.connected);
      await clean('unplugged');
      expect(find.byKey(const Key('invite')), findsOneWidget);
      expect(ctl.pendingVoice, -1);
      expect(tester.widget<Text>(find.byKey(const Key('hover-readout'))).data, '', reason: 'no key under the pointer of a board that left');
      expect(find.byType(Knob), findsNothing, reason: 'no parameters without a board');

      // the board is back: the lists again, the current voice's row current, no pending bar
      usb.present = true;
      await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty, ms: 15000);
      await clean('reconnected');
      expect(find.byKey(const Key('invite')), findsNothing);
      expect(ctl.pendingVoice, -1);
      final rows = tester.widgetList<ListRow>(find.byType(ListRow));
      expect(rows.where((r) => r.pending), isEmpty, reason: 'no row waits for a board that answered');
      expect(rows.where((r) => r.current).length, 1, reason: 'the voice the board plays');
      expect(find.byType(Knob), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await clean('stage after reconnect');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, ms: 400);

      await finish(tester, ctl);
      await disposeBoard(tester, b);
    });
  }
}
