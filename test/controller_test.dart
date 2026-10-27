// The reconnect rules and the session logic of the controller against the real firmware: a fake
// USB backend whose Striso is the virtual board (striso_virtual; no window). Unplugged: USB says
// nothing is there and the board restarts. What it cannot be (busy, an old firmware, a reply its
// firmware never gives) is a canned reply (support/app2.dart).
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/theme.dart';
import 'package:striso_live/src/virtual_support.dart' show shortVersion;

import 'support/app2.dart';
import 'support/virtual.dart';

AppController make(UsbBackend usb, {String? intent}) {
  final store = Store.memory();
  if (intent != null) store.set('usbIntent', intent);
  return AppController(options: const AppOptions(), store: store, usb: usb);
}

void main() {
  final skip = virtualSkip != null;

  /// Connected, the lists read.
  Future<void> live(WidgetTester tester, AppController ctl, {int ms = 10000}) =>
      waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading, ms: ms);

  testWidgets('at start: connects right away when the user left the board connected', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(VirtualUsb(b), intent: 'connected');
    await run(tester, ctl.start());
    await live(tester, ctl);
    expect(ctl.mode, Mode.striso);
    expect(ctl.status, 'Connected');
    expect(ctl.trace!.keys, containsAll(['connect', 'version', 'live']));
    expect(ctl.voices.length, b.state.voices);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('the trumpet: the eighth engine button in cyan, its hero knobs from the board', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(VirtualUsb(b), intent: 'connected');
    await run(tester, ctl.start());
    await live(tester, ctl);
    final row = ctl.engines();
    expect(row.map((e) => e.engine).take(8), ['strisy', 'va', 'modal', 'bowed', 'wind', 'ep', 'brass', 'trumpet']);
    expect(engineColor('trumpet'), const Color(0xFF2BB7C9));
    expect(engineInfo('trumpet').label, 'Trumpet');
    expect(engineInfo('trumpet').blurb, 'physical model, valves and mutes');
    expect(ctl.settingsLayout[15]!.engine, 'trumpet', reason: 'the board lists its voice keys (StcX)');
    expect(ctl.settingsLayout[15]!.switchable, isTrue);
    ctl.selectEngine('trumpet');
    await waitFor(tester, () => ctl.voiceName == 'trumpet:trumpet' && ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().map((p) => p.name), ['brassiness', 'bell_hz', 'tone_hz', 'tongue', 'p_loud', 'breath', 'lip_tilt', 'release']);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  // The firmware release (v2.2.4-335, tagged) reports "2026-10-25_v2.2.4-335-0-g<sha>_all"; the app
  // needs v2.2.4-338-93 or newer. It compares no version numbers: what it needs is that the firmware
  // answers StcG, StcX, Stcy and StcH, so a tagged build's string is taken as it is, and its commit
  // read.
  test('a tagged firmware release\'s version string: parsed, its commit read', () {
    const tagged = '2026-10-25_v2.2.4-335-0-g1a2b3c4_all';
    final v = parseVersion('striso_control_strisoboard_$tagged 0043002B3132510A33383339 STRISO');
    expect(v.fw, 'strisoboard_$tagged');
    expect(commitOf(v.fw), '1a2b3c4');
    expect(commitOf(tagged), '1a2b3c4');
    expect(shortVersion(tagged), '1a2b3c4');
    expect(minFirmware, 'v2.2.4-338-93');
  });
  testWidgets('the firmware release (a tagged build\'s version string) connects: the app asks for what it needs, not a number', skip: skip, (
    tester,
  ) async {
    final b = await startBoard(tester);
    // the board as it is, but StcV answers with the release's string
    final usb = CannedUsb(b, {
      'V': ['striso_control_strisoboard_2026-10-25_v2.2.4-335-0-g1a2b3c4_all 0043002B3132510A33383339 STRISO'],
    });
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    await live(tester, ctl);
    expect(ctl.problem, isNull);
    expect(ctl.strisoVersion!.fw, 'strisoboard_2026-10-25_v2.2.4-335-0-g1a2b3c4_all');
    expect(commitOf(ctl.strisoVersion!.fw), '1a2b3c4');
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });
  testWidgets('an older firmware: no session, the problem says which firmware the app needs and what to do', (tester) async {
    // the firmware as released upstream: it answers StcV, not StcG, StcX, Stcy or StcH
    final usb = ScriptedUsb({
      'V': ['striso_control_strisoboard_v2.2.4 0043002B3132510A33383339 STRISO'],
    });
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.problem != null);
    expect(ctl.connected, isFalse);
    final p = ctl.problem!;
    expect(p.title, 'This Striso needs a firmware update');
    expect(p.detail, contains(minFirmware));
    expect(p.detail, contains('runs strisoboard_v2.2.4.'));
    expect(p.detail, contains('Flash a newer firmware'));
    expect(p.actions, containsAll([Fix.copyVersion, Fix.playVirtual]));
    await finish(tester, ctl);
  });
  testWidgets('a firmware without the key layout (StcG) needs an update, like one without StcX: no keys guessed', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(CannedUsb(b, {'G': []}), intent: 'connected');
    expect(ctl.keyLayout, isNull);
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.problem != null);
    expect(ctl.connected, isFalse);
    expect(ctl.problem!.title, 'This Striso needs a firmware update');
    expect(ctl.problem!.detail, contains(minFirmware));
    expect(ctl.keyLayout, isNull);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });
  testWidgets('the key layout is the board\'s (StcG), kept as it sent it for the next start', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final store = Store.memory()..set('usbIntent', 'connected');
    final ctl = AppController(options: const AppOptions(), store: store, usb: VirtualUsb(b));
    expect(ctl.keyLayout, isNull, reason: 'no board has reported: no keys');
    await run(tester, ctl.start());
    await live(tester, ctl);
    final board = (await run(tester, ctl.client!.getKeyLayout()))!;
    final l = ctl.keyLayout!;
    expect(l.lines, board.lines);
    expect(l.keys.length, board.keys.length);
    expect(ctl.live.pres.length, board.buttons);
    expect(store.raw('keyLayout'), board.lines);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
    // the next start: the last board's keys before any board reports
    final next = AppController(options: const AppOptions(), store: store, usb: ScriptedUsb({}));
    expect(next.keyLayout!.lines, board.lines);
    expect(next.keyLayout!.keyIds, board.keyIds);
    await finish(tester, next);
  });
  testWidgets('first launch (nothing chosen yet): a Striso on USB connects by itself; one plugged in later too, after 4 s', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(VirtualUsb(b));
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on);
    expect(ctl.connected, isTrue);
    expect(ctl.intent, 'connected');
    await finish(tester, ctl);

    final usb2 = VirtualUsb(b)..present = false;
    final ctl2 = make(usb2);
    await run(tester, ctl2.start());
    expect(ctl2.invite!.title, 'Plug in your Striso');
    expect(ctl2.invite!.actions, [Fix.playVirtual]);
    expect(ctl2.connectLabel, '', reason: 'nothing to end');
    usb2.present = true;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(ctl2.reconnectPending, isTrue);
    expect(ctl2.invite!.title, 'Striso found');
    expect(ctl2.connectLabel, 'Cancel');
    await waitFor(tester, () => ctl2.dot == Dot.on);
    expect(ctl2.connected, isTrue);
    expect(ctl2.connectLabel, 'Disconnect');
    await finish(tester, ctl2);
    await disposeBoard(tester, b);
  });

  testWidgets('at start: stays away after a Disconnect, and when the board is plugged in', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = VirtualUsb(b);
    final ctl = make(usb, intent: 'off');
    await run(tester, ctl.start());
    expect(ctl.connected, isFalse);
    expect(ctl.status, startsWith('Disconnected'));
    usb.present = false;
    await tester.pump(const Duration(seconds: 2));
    usb.present = true;
    await tester.pump(const Duration(seconds: 7));
    expect(ctl.connected, isFalse);
    expect(ctl.reconnectPending, isFalse);
    expect(usb.opened, 0);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('unplug, then replug: reconnects 4 s after the board is back', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = VirtualUsb(b);
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on);
    await unplug(tester, usb);
    await waitFor(tester, () => !ctl.connected);
    expect(ctl.status, 'Unplugged');
    expect(ctl.banner?.info, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(ctl.connected, isFalse);
    usb.present = true;
    await tester.pump(const Duration(milliseconds: 1500)); // the next presence poll
    expect(ctl.reconnectPending, isTrue);
    expect(ctl.connectLabel, 'Cancel');
    await tester.pump(const Duration(seconds: 2));
    expect(ctl.connected, isFalse, reason: 'waits 4 s: a flash tool gets the board first');
    await waitFor(tester, () => ctl.dot == Dot.on);
    expect(ctl.connected, isTrue);
    expect(usb.opened, 2);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('a busy board is retried quietly, then connects', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = BusyUsb(b)..present = false;
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    usb
      ..busy = 2
      ..present = true;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(ctl.reconnectPending, isTrue);
    await tester.pump(const Duration(milliseconds: 4100)); // first try: busy
    await tester.pump(const Duration(milliseconds: 50));
    expect(ctl.status, 'Striso busy · trying again');
    expect(ctl.banner, isNull, reason: 'quiet while retrying');
    await waitFor(tester, () => ctl.dot == Dot.on, ms: 12000);
    expect(ctl.connected, isTrue);
    expect(usb.busy, 0);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('Cancel while a reconnect waits: no connection, intent off', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = VirtualUsb(b)..present = false;
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    usb.present = true;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(ctl.reconnectPending, isTrue);
    await run(tester, ctl.connectButton()); // 'Cancel'
    expect(ctl.reconnectPending, isFalse);
    expect(ctl.intent, 'off');
    await tester.pump(const Duration(seconds: 6));
    expect(ctl.connected, isFalse);
    expect(usb.opened, 0);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('Connect with no board: a problem with its fix, no session', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = VirtualUsb(b)..present = false;
    final ctl = make(usb);
    await run(tester, ctl.start());
    await run(tester, ctl.userConnect());
    expect(ctl.connected, isFalse);
    expect(ctl.problem!.title, 'No Striso on USB');
    expect(ctl.problem!.actions, [Fix.playVirtual]);
    expect(ctl.status, 'No Striso on USB');
    expect(ctl.banner, isNull);
    usb.present = true;
    await run(tester, ctl.userConnect());
    await waitFor(tester, () => ctl.dot == Dot.on);
    expect(ctl.intent, 'connected');
    await run(tester, ctl.userDisconnect());
    expect(ctl.intent, 'off');
    expect(ctl.connected, isFalse);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('presets: save, recall onto another voice, export and import', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(VirtualUsb(b), intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty);
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    ctl.onEdit(0, p, (p.min + p.max) / 2, 'begin', 'x');
    ctl.onEdit(0, p, p.value, 'end');
    final want = p.value;
    ctl.saveCurrent('Velvet');
    expect(ctl.presets.single.name, 'Velvet');
    final json = ctl.exportPresets();
    ctl.deletePreset(ctl.presets.single);
    expect(ctl.presets, isEmpty);
    ctl.importPresets(json);
    expect(ctl.presets.single.voice, ctl.voiceName);
    // to another voice and back by recalling the sound
    final other = ctl.voices.firstWhere((v) => v.engine == 'modal');
    await run(tester, ctl.selectVoice(other.index));
    expect(ctl.voiceName, other.name);
    await run(tester, ctl.recallPreset(ctl.presets.single));
    expect(ctl.voiceName.split(':').first, 'va');
    expect(ctl.findParam(0, p.name)!.value, want);
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, closeTo(want, 1e-6), reason: 'on the board');
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });
  testWidgets('the edited sound comes back after a reconnect, with a Restore action', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = VirtualUsb(b);
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty);
    final name = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous).name;
    final p = ctl.findParam(0, name)!;
    ctl.onEdit(0, p, (p.min + p.max) / 2 + (p.max - p.min) * 0.1, 'begin', 'x');
    ctl.onEdit(0, p, p.value, 'end');
    ctl.frame(clockMs(), 16);
    final want = p.value;
    await tester.pump(const Duration(seconds: 1)); // the edits are kept after 0.8 s
    // the board restarts: its preset's values again
    await unplug(tester, usb);
    await waitFor(tester, () => !ctl.connected);
    usb.present = true;
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading, ms: 12000);
    expect(ctl.findParam(0, name)!.value, isNot(want));
    final t = ctl.toasts.value.where((x) => x.action == 'Restore').firstOrNull;
    expect(t, isNotNull, reason: 'a Restore toast');
    expect(t!.text, contains('is back'));
    t.onAction!();
    expect(ctl.findParam(0, name)!.value, want);
    expect(ctl.history.canUndo, isTrue);
    await settle(tester);
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, closeTo(want, 1e-6), reason: 'restored on the board');
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('an edit shows pending until the board reads it back; then the board’s value', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final ctl = make(VirtualUsb(b), intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty);
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    final v = conformValue(p, p.min + 0.8 * (p.max - p.min));
    ctl.onEdit(0, p, v, 'begin', 'x');
    ctl.onEdit(0, p, v, 'end');
    expect(ctl.sound.isPending(0, p), isTrue);
    await waitFor(tester, () => !ctl.sound.isPending(0, p), ms: 4000);
    expect(ctl.sound.isPending(0, p), isFalse, reason: 'confirmed by the board');
    expect(p.value, closeTo(v, 1e-6));
    expect((await run(tester, ctl.client!.getParams(0)))!.params[p.index].value, closeTo(v, 1e-6));
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });

  testWidgets('hero knobs are the board’s (StcH); a name the board does not list is an error, not a guess', skip: skip, (tester) async {
    final b = await startBoard(tester);
    final usb = CannedUsb(b);
    final ctl = make(usb, intent: 'connected');
    await run(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.mainKnobs().isNotEmpty);
    expect(ctl.voiceName, 'va:classic');
    expect(ctl.mainKnobs().map((p) => p.name), ['cut_base', 'res', 'cut_env', 'drive', 'saw2_detune', 'sub', 'release', 'vibrato']);
    expect(ctl.mainFx().map((p) => p.name), ['rvmix', 'dlmix']);
    expect(ctl.heroMissing, isEmpty);
    // a board that names a knob its list does not have (no firmware does: a canned StcH)
    usb.answers['H'] = ['H ${ctl.current} cut_base no_such_knob res | rvmix'];
    await run(tester, ctl.syncVoice());
    expect(ctl.mainKnobs().map((p) => p.name), ['cut_base', 'res'], reason: 'only what the board lists');
    expect(ctl.heroMissing, ['no_such_knob']);
    await finish(tester, ctl);
    await disposeBoard(tester, b);
  });
}
