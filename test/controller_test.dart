// The reconnect rules and the session logic of the controller, against a fake USB backend whose
// "board" is the demo board (no USB, no window).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/store.dart';

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
    return last = MockTransport(board: MockBoard(autoplay: false, idleFrames: 0));
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
    expect(ctl.mode, ConnMode.usb);
    expect(ctl.status, 'Connected');
    expect(ctl.trace!.keys, containsAll(['connect', 'version', 'live']));
    expect(ctl.voices.length, 56);
    await finish(tester, ctl);
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
    expect(ctl.status, 'Board busy (being updated?)');
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

  testWidgets('Connect with no board: a banner, no session', (tester) async {
    final usb = FakeUsb()..present = false;
    final ctl = make(usb);
    await pumpUntil(tester, ctl.start());
    await pumpUntil(tester, ctl.userConnect());
    expect(ctl.connected, isFalse);
    expect(ctl.banner?.text, contains('No Striso found'));
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
}
