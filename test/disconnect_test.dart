// The user's reports: "Disconnect doesn't actually disconnect", "while disconnected, Through PC is
// still on and it works", "the connection status is wrong". After Disconnect nothing may run: no
// USB transport open, no audio device, no MIDI input, no virtual board, no timer or poller. Through
// PC plays only while a Striso session is live. The Striso on USB and Virtual are the virtual board
// (the real firmware); fake audio, fake MIDI, fake time for the app, real time for the board
// between the app's steps ([pass]).
import 'dart:io' show sleep;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/session/resources.dart';
import 'package:striso_live/src/store.dart';
import 'package:striso_virtual/striso_virtual.dart';

import 'support/app2.dart';
import 'support/virtual.dart';

/// USB whose Striso is the virtual board; counts what is open.
class CountingUsb extends VirtualUsb {
  final transports = <VirtualBoardTransport>[];
  CountingUsb(super.board);
  int get open => transports.where((t) => t.isOpen).length;

  @override
  Transport transport() {
    final t = super.transport() as VirtualBoardTransport;
    transports.add(t);
    return t;
  }
}

class Rig {
  final VirtualBoard board;
  final CountingUsb usb;
  final audio = FakeAudioBackend();
  final midi = FakeMidiBackend();
  late final AppController ctl;

  /// [disconnected]: the user let go of the Striso the last time (so start does not connect it).
  Rig._(this.board, {required bool through, required bool disconnected}) : usb = CountingUsb(board) {
    final store = Store.memory();
    if (disconnected) store.set('usbIntent', 'off');
    ctl = AppController(options: AppOptions(virtualLib: virtualLib), store: store, usb: usb, audioBackend: audio, midiBackend: midi);
    if (through) ctl.audio.setThrough(true);
  }
  Rig({bool through = true, bool disconnected = true})
    : this._(VirtualBoard(libPath: virtualLib)..startRealtime(), through: through, disconnected: disconnected);

  /// [ms] of the app's fake time, a quarter of it in real time for the boards (the client's
  /// timeouts are on the fake clock, generous for the board's answers). Virtual's board, while the
  /// output holds its clock, is rendered as the output's callback would: [step] of it each step.
  void pass(FakeAsync async, int ms, {int step = 20}) {
    for (var t = 0; t < ms; t += step) {
      sleep(Duration(milliseconds: step ~/ 4));
      final v = ctl.virtual.instrument?.board;
      if (v != null && !v.disposed && !v.realtime) v.render(48 * step);
      async.elapse(Duration(milliseconds: step));
    }
  }

  /// [pass] until [cond], at most [ms] of fake time.
  void until(FakeAsync async, bool Function() cond, {int ms = 10000}) {
    for (var t = 0; t < ms && !cond(); t += 20) {
      pass(async, 20);
    }
    expect(cond(), isTrue, reason: 'condition not met in $ms ms');
  }

  /// Live, the lists read.
  void live(FakeAsync async) => until(async, () => ctl.state is Live && !ctl.listsLoading);

  /// Disconnect, then every poller's last round and the toasts.
  void disconnect(FakeAsync async) {
    ctl.userDisconnect();
    pass(async, 1000);
    async.elapse(const Duration(seconds: 7));
  }

  /// Nothing of the session is left: the assertion of the user's report.
  void expectNothingRuns(FakeAsync async, {String when = ''}) {
    expect(usb.open, 0, reason: 'no USB transport open $when');
    expect(ctl.client, isNull);
    expect(ctl.virtual.instrument, isNull, reason: 'no virtual board runs $when');
    expect(audio.anyOpen, isFalse, reason: 'no audio device open $when');
    expect(audio.last.run, isFalse, reason: 'the audio engine asked to close everything $when');
    expect(ctl.audio.ticking, isFalse, reason: 'the audio engine\'s timer stopped $when');
    expect(midi.devices().where((d) => d.open && !d.isVirtual), isEmpty, reason: 'no MIDI input open $when');
    expect(ctl.midi!.running, isFalse);
    expect(ctl.session.resources.active, isEmpty, reason: 'still running: ${ctl.session.resources} $when');
    expect(async.periodicTimerCount, 0, reason: 'no periodic timer $when: ${async.pendingTimersDebugString}');
    expect(async.pendingTimers, isEmpty, reason: 'no timer at all $when: ${async.pendingTimersDebugString}');
  }

  void dispose() {
    ctl.dispose();
    board.dispose();
  }
}

void main() {
  final skip = virtualSkip != null;

  test('Disconnect ends everything: the console, the stream, the pollers, Through PC; Connect brings it back', skip: skip, () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      r.pass(async, 2000);
      // not connected: Through PC is on, but nothing plays
      expect(ctl.state, isA<Idle>());
      expect(r.audio.anyOpen, isFalse, reason: 'Through PC without a session plays nothing');
      ctl.userConnect();
      r.live(async);
      r.pass(async, 200);
      expect(ctl.status, 'Connected');
      expect(r.usb.open, 1);
      expect(r.audio.last.run, isTrue);
      expect(r.audio.last.monitor, isTrue, reason: 'Through PC plays while the Striso is connected');
      expect(r.audio.anyOpen, isTrue);
      expect(ctl.session.resources.has(Res.console), isTrue);
      expect(ctl.session.resources.has(Res.loadPoll), isTrue);
      expect(ctl.session.resources.has(Res.audioInput), isTrue);
      expect(ctl.soundLine, startsWith('Striso · Through PC'));

      r.disconnect(async);
      expect(ctl.state, isA<Idle>());
      expect(ctl.status, startsWith('Disconnected'));
      expect(ctl.dot, Dot.off);
      expect(ctl.connectLabel, '', reason: 'nothing to end; the segments and the start screen act');
      expect(ctl.soundLine, isEmpty);
      r.expectNothingRuns(async, when: 'after Disconnect');
      expect(ctl.audio.through, isTrue, reason: 'the choice is kept for the next session');

      // Connect: all of it again, as the user left it
      ctl.userConnect();
      r.live(async);
      r.pass(async, 200);
      expect(r.audio.last.monitor, isTrue);
      expect(r.audio.anyOpen, isTrue);
      r.disconnect(async);
      r.expectNothingRuns(async, when: 'after the second Disconnect');
      r.dispose();
    });
  });

  test('unplugged: Through PC closes at once; the status says Unplugged; replugged it comes back', skip: skip, () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      ctl.userConnect();
      r.live(async);
      r.pass(async, 200);
      expect(r.audio.anyOpen, isTrue);
      pullCable(r.usb);
      r.pass(async, 200);
      expect(ctl.status, 'Unplugged');
      expect(r.audio.anyOpen, isFalse, reason: 'no Striso, no Through PC');
      expect(ctl.session.resources.has(Res.presence), isTrue, reason: 'it waits for the Striso to come back');
      r.until(async, () => r.board.attached, ms: 8000); // the board has restarted
      r.usb.present = true;
      r.until(async, () => ctl.state is Live, ms: 12000);
      r.live(async);
      r.pass(async, 200);
      expect(r.audio.anyOpen, isTrue);
      r.disconnect(async);
      r.expectNothingRuns(async);
      r.dispose();
    });
  });

  test('Virtual: its output and MIDI run only while it is live; Disconnect stops them all', skip: skip, () {
    fakeAsync((async) {
      final r = Rig(through: false);
      final ctl = r.ctl;
      r.midi.plug('ls', name: 'LinnStrument MIDI');
      ctl.midi!.select('ls', true);
      ctl.start();
      ctl.playVirtual();
      r.live(async);
      r.pass(async, 200);
      expect(ctl.mode, Mode.virtual);
      expect(r.audio.last.outputOnly, isTrue, reason: 'Virtual plays to the output with Through PC off');
      expect(r.audio.anyOpen, isTrue);
      expect(r.usb.open, 0, reason: 'Virtual holds no USB session');
      expect(ctl.midi!.running, isTrue);
      expect(r.midi.devices().firstWhere((d) => d.id == 'ls').open, isTrue);
      expect(ctl.soundLine, contains('input: LinnStrument MIDI'));
      r.disconnect(async);
      r.expectNothingRuns(async, when: 'after Virtual');
      r.dispose();
    });
  });

  test('switching modes is a full teardown: Striso to Virtual leaves no USB, no input; and back', skip: skip, () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      ctl.userConnect();
      r.live(async);
      r.pass(async, 200);
      expect(r.audio.last.monitor, isTrue);
      ctl.setMode(Mode.virtual);
      r.until(async, () => ctl.mode == Mode.virtual && ctl.state is Live && !ctl.listsLoading);
      r.pass(async, 200);
      expect(r.usb.open, 0, reason: 'the Striso session ended');
      expect(r.audio.last.outputOnly, isTrue);
      expect(r.audio.last.input, '', reason: 'the Striso\'s audio input is closed');
      ctl.setMode(Mode.striso);
      r.until(async, () => ctl.mode == Mode.striso && ctl.state is Live && !ctl.listsLoading);
      r.pass(async, 200);
      expect(ctl.virtual.instrument, isNull, reason: 'Virtual stopped');
      expect(r.usb.open, 1);
      expect(r.audio.last.monitor, isTrue);
      r.disconnect(async);
      r.expectNothingRuns(async);
      r.dispose();
    });
  });
}
