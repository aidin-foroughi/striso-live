// The reconnect rules and the session logic of the controller, against a fake USB backend whose
// "board" is the demo board (no USB, no window).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_live/src/theme.dart';
import 'package:striso_live/src/virtual_support.dart' show shortVersion;

class _BusyTransport implements Transport {
  @override
  String get label => 'busy';
  @override
  Stream<Uint8List> get data => const Stream.empty();
  @override
  Future<UsbError> get lost => Completer<UsbError>().future;
  @override
  Future<void> open() async => throw UsbError.busy;
  @override
  Future<void> write(Uint8List bytes) async {}
  @override
  Future<void> close() async {}
}

class FakeUsb implements UsbBackend {
  bool present = true;
  int busy = 0, opened = 0, probes = 0;

  /// The board runs the firmware as released upstream (no StcX, StcY, StcH).
  bool stock = false;

  /// The firmware the board reports (StcV), when not the mock's own.
  String? firmware;
  MockTransport? last;

  @override
  Future<({bool present, String where})> probe() async {
    probes++;
    return (present: present, where: 'fake');
  }

  @override
  Transport transport() {
    if (busy > 0) {
      busy--;
      return _BusyTransport();
    }
    opened++;
    return last = MockTransport(board: MockBoard(autoplay: false, idleFrames: 0, stockFirmware: stock, firmware: firmware ?? (stock ? 'striso_control_strisoboard_v2.2.4' : 'striso_control_strisoboard_v2.2.4-voices-mock')));
  }

  /// Pull the cable.
  void unplug() {
    present = false;
    last?.unplug();
  }

  @override
  Future<void> dispose() async {}
}

/// Awaits [f] while fake time moves on; real time too (the demo board's clock).
Future<T> pumpUntil<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T value;
  f.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 300 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (!done) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
  expect(done, isTrue, reason: 'did not finish');
  return value;
}

Future<void> waitFor(WidgetTester tester, bool Function() cond, {int ms = 8000}) async {
  for (var t = 0; t < ms && !cond(); t += 20) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  }
}

Future<void> finish(WidgetTester tester, AppController ctl) async {
  await pumpUntil(tester, ctl.endSession());
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  ctl.dispose();
}

AppController make(FakeUsb usb, {String? intent}) {
  final store = Store.memory();
  if (intent != null) store.set('usbIntent', intent);
  return AppController(options: const AppOptions(), store: store, usb: usb);
}

void main() {
  testWidgets('at start: connects right away when the user left the board connected', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
    expect(ctl.mode, Mode.striso);
    expect(ctl.status, 'Connected');
    expect(ctl.trace!.keys, containsAll(['connect', 'version', 'live']));
    expect(ctl.voices.length, 65);
    await finish(tester, ctl);
  });

  testWidgets('the trumpet: the eighth engine button in cyan, its hero knobs, the mutes lead with mute and wah', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
    final row = ctl.engines();
    expect(row.map((e) => e.engine).take(8), ['strisy', 'va', 'modal', 'bowed', 'wind', 'ep', 'brass', 'trumpet']);
    expect(engineColor('trumpet'), const Color(0xFF2BB7C9));
    expect(engineInfo('trumpet').label, 'Trumpet');
    expect(engineInfo('trumpet').blurb, 'physical model, valves and mutes');
    expect(ctl.settingsLayout[15]!.engine, 'trumpet', reason: 'the board lists its voice keys (StcX)');
    expect(ctl.settingsLayout[15]!.switchable, isTrue);
    ctl.selectEngine('trumpet');
    await waitFor(tester, () => ctl.voiceName == 'trumpet:bb classical' && ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().map((p) => p.name), ['brassy', 'bell', 'attack', 'p_loud', 'breath', 'vibrato', 'release', 'room']);
    final cup = ctl.voices.firstWhere((v) => v.name == 'trumpet:cup mute');
    await pumpUntil(tester, ctl.selectVoice(cup.index));
    await waitFor(tester, () => ctl.voiceName == 'trumpet:cup mute' && ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().map((p) => p.name).take(2), ['mute', 'wah']);
    await finish(tester, ctl);
  });

  // The firmware release (v2.2.4-335, tagged) reports "2026-10-25_v2.2.4-335-0-g<sha>_all"; the app
  // needs v2.2.4-231 or newer. It compares no version numbers: what it needs is that the firmware
  // answers StcX, Stcy and StcH, so a tagged build's string is taken as it is, and its commit read.
  test('a tagged firmware release\'s version string: parsed, its commit read', () {
    const tagged = '2026-10-25_v2.2.4-335-0-g1a2b3c4_all';
    final v = parseVersion('striso_control_strisoboard_$tagged 0043002B3132510A33383339 STRISO');
    expect(v.fw, 'strisoboard_$tagged');
    expect(commitOf(v.fw), '1a2b3c4');
    expect(commitOf(tagged), '1a2b3c4');
    expect(shortVersion(tagged), '1a2b3c4');
    expect(minFirmware, 'v2.2.4-231');
  });
  testWidgets('the firmware release (a tagged build\'s version string) connects: the app asks for what it needs, not a number', (tester) async {
    final usb = FakeUsb()..firmware = 'striso_control_strisoboard_2026-10-25_v2.2.4-335-0-g1a2b3c4_all';
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
    expect(ctl.problem, isNull);
    expect(ctl.strisoVersion!.fw, 'strisoboard_2026-10-25_v2.2.4-335-0-g1a2b3c4_all');
    expect(commitOf(ctl.strisoVersion!.fw), '1a2b3c4');
    await finish(tester, ctl);
  });
  testWidgets('an older firmware: no session, the problem says which firmware the app needs and what to do', (tester) async {
    final usb = FakeUsb()..stock = true;
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
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
  testWidgets('first launch (nothing chosen yet): a Striso on USB connects by itself; one plugged in later too, after 4 s', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb);
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading);
    expect(ctl.connected, isTrue);
    expect(ctl.intent, 'connected');
    await finish(tester, ctl);

    final usb2 = FakeUsb()..present = false;
    final ctl2 = make(usb2);
    await pumpUntil(tester, ctl2.start());
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
  });

  testWidgets('at start: stays away after a Disconnect, and when the board is plugged in', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'off');
    await pumpUntil(tester, ctl.start());
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
  });

  testWidgets('unplug, then replug: reconnects 4 s after the board is back', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on);
    usb.unplug();
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
  });

  testWidgets('a busy board is retried quietly, then connects', (tester) async {
    final usb = FakeUsb()..present = false;
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
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
  });

  testWidgets('Cancel while a reconnect waits: no connection, intent off', (tester) async {
    final usb = FakeUsb()..present = false;
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    usb.present = true;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(ctl.reconnectPending, isTrue);
    await pumpUntil(tester, ctl.connectButton()); // 'Cancel'
    expect(ctl.reconnectPending, isFalse);
    expect(ctl.intent, 'off');
    await tester.pump(const Duration(seconds: 6));
    expect(ctl.connected, isFalse);
    expect(usb.opened, 0);
    await finish(tester, ctl);
  });

  testWidgets('Connect with no board: a problem with its fix, no session', (tester) async {
    final usb = FakeUsb()..present = false;
    final ctl = make(usb);
    await pumpUntil(tester, ctl.start());
    await pumpUntil(tester, ctl.userConnect());
    expect(ctl.connected, isFalse);
    expect(ctl.problem!.title, 'No Striso on USB');
    expect(ctl.problem!.actions, [Fix.playVirtual]);
    expect(ctl.status, 'No Striso on USB');
    expect(ctl.banner, isNull);
    usb.present = true;
    await pumpUntil(tester, ctl.userConnect());
    await waitFor(tester, () => ctl.dot == Dot.on);
    expect(ctl.intent, 'connected');
    await pumpUntil(tester, ctl.userDisconnect());
    expect(ctl.intent, 'off');
    expect(ctl.connected, isFalse);
    await finish(tester, ctl);
  });

  testWidgets('presets: save, recall onto another voice, export and import', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
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
    await pumpUntil(tester, ctl.selectVoice(other.index));
    expect(ctl.voiceName, other.name);
    await pumpUntil(tester, ctl.recallPreset(ctl.presets.single));
    expect(ctl.voiceName.split(':').first, 'va');
    expect(ctl.findParam(0, p.name)!.value, want);
    await finish(tester, ctl);
  });
  testWidgets('the edited sound comes back after a reconnect, with a Restore action', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty);
    final name = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous).name;
    final p = ctl.findParam(0, name)!;
    ctl.onEdit(0, p, (p.min + p.max) / 2 + (p.max - p.min) * 0.1, 'begin', 'x');
    ctl.onEdit(0, p, p.value, 'end');
    ctl.frame(clockMs(), 16);
    final want = p.value;
    await tester.pump(const Duration(seconds: 1)); // the edits are kept after 0.8 s
    // the board restarts: a fresh board with the preset's values
    usb.unplug();
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
    await finish(tester, ctl);
  });

  testWidgets('an edit shows pending until the board reads it back; then the board’s value', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.params[0]!.params.isNotEmpty);
    final p = ctl.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    final v = conformValue(p, p.min + 0.8 * (p.max - p.min));
    ctl.onEdit(0, p, v, 'begin', 'x');
    ctl.onEdit(0, p, v, 'end');
    expect(ctl.sound.isPending(0, p), isTrue);
    await waitFor(tester, () => !ctl.sound.isPending(0, p), ms: 4000);
    expect(ctl.sound.isPending(0, p), isFalse, reason: 'confirmed by the board');
    expect(p.value, closeTo(v, 1e-6));
    expect(usb.last!.board.values[p.index], closeTo(v, 1e-6));
    await finish(tester, ctl);
  });

  testWidgets('hero knobs are the board\u2019s (StcH); a name the board does not list is an error, not a guess', (tester) async {
    final usb = FakeUsb();
    final ctl = make(usb, intent: 'connected');
    await pumpUntil(tester, ctl.start());
    await waitFor(tester, () => ctl.dot == Dot.on && !ctl.listsLoading && ctl.mainKnobs().isNotEmpty);
    expect(ctl.mainKnobs().map((p) => p.name), mockHeroReplies[ctl.voiceName]!.split(' | ').first.split(' '));
    expect(ctl.mainFx().map((p) => p.name), ['rvmix', 'dlmix']);
    expect(ctl.heroMissing, isEmpty);
    // the board names a knob its list does not have
    usb.last!.board.heroReply = (v) => 'cut_base no_such_knob res | rvmix';
    await pumpUntil(tester, ctl.syncVoice());
    expect(ctl.mainKnobs().map((p) => p.name), ['cut_base', 'res'], reason: 'only what the board lists');
    expect(ctl.heroMissing, ['no_such_knob']);
    await finish(tester, ctl);
  });
}
