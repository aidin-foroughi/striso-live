// The user's reports: "Disconnect doesn't actually disconnect", "while disconnected, Through PC is
// still on and it works", "the connection status is wrong". After Disconnect nothing may run: no
// USB transport open, no audio device, no MIDI input, no timer or poller. Through PC plays only
// while a Striso session is live. Fake USB (the Dart mock board), fake audio, fake MIDI, fake time.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart';
import 'package:striso_live/src/session/resources.dart';
import 'package:striso_live/src/store.dart';

/// USB whose board is the Dart mock; counts what is open.
class CountingUsb implements UsbBackend {
  bool present = true;
  final transports = <MockTransport>[];
  int get open => transports.where((t) => t.alive).length;

  @override
  Future<({bool present, String where})> probe() async => (present: present, where: 'fake');
  @override
  Transport transport() {
    final t = MockTransport(board: MockBoard(autoplay: false, idleFrames: 0));
    transports.add(t);
    return t;
  }

  @override
  Future<void> dispose() async {}
}

class Rig {
  final usb = CountingUsb();
  final audio = FakeAudioBackend();
  final midi = FakeMidiBackend();
  late final AppController ctl;
  Rig({bool through = true}) {
    final store = Store.memory();
    ctl = AppController(options: const AppOptions(), store: store, usb: usb, audioBackend: audio, midiBackend: midi);
    if (through) ctl.audio.setThrough(true);
  }

  /// Nothing of the session is left: the assertion of the user's report.
  void expectNothingRuns(FakeAsync async, {String when = ''}) {
    expect(usb.open, 0, reason: 'no USB transport open $when');
    expect(ctl.client, isNull);
    expect(audio.anyOpen, isFalse, reason: 'no audio device open $when');
    expect(audio.last.run, isFalse, reason: 'the audio engine asked to close everything $when');
    expect(ctl.audio.ticking, isFalse, reason: 'the audio engine\'s timer stopped $when');
    expect(midi.devices().where((d) => d.open && !d.isVirtual), isEmpty, reason: 'no MIDI input open $when');
    expect(ctl.midi!.running, isFalse);
    expect(ctl.session.resources.active, isEmpty, reason: 'still running: ${ctl.session.resources} $when');
    expect(async.periodicTimerCount, 0, reason: 'no periodic timer $when: ${async.pendingTimersDebugString}');
    expect(async.pendingTimers, isEmpty, reason: 'no timer at all $when: ${async.pendingTimersDebugString}');
  }
}

void main() {
  test('Disconnect ends everything: the console, the stream, the pollers, Through PC; Connect brings it back', () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      async.elapse(const Duration(seconds: 2));
      // not connected: Through PC is on, but nothing plays
      expect(ctl.state, isA<Idle>());
      expect(r.audio.anyOpen, isFalse, reason: 'Through PC without a session plays nothing');
      ctl.userConnect();
      async.elapse(const Duration(seconds: 3));
      expect(ctl.state, isA<Live>());
      expect(ctl.status, 'Connected');
      expect(r.usb.open, 1);
      expect(r.audio.last.run, isTrue);
      expect(r.audio.last.monitor, isTrue, reason: 'Through PC plays while the Striso is connected');
      expect(r.audio.anyOpen, isTrue);
      expect(ctl.session.resources.has(Res.console), isTrue);
      expect(ctl.session.resources.has(Res.loadPoll), isTrue);
      expect(ctl.session.resources.has(Res.audioInput), isTrue);
      expect(ctl.soundLine, startsWith('Striso · Through PC'));

      ctl.userDisconnect();
      async.elapse(const Duration(seconds: 8)); // every poller's last round, the toasts
      expect(ctl.state, isA<Idle>());
      expect(ctl.status, startsWith('Disconnected'));
      expect(ctl.dot, Dot.off);
      expect(ctl.connectLabel, 'Connect');
      expect(ctl.soundLine, isEmpty);
      r.expectNothingRuns(async, when: 'after Disconnect');
      expect(ctl.audio.through, isTrue, reason: 'the choice is kept for the next session');

      // Connect: all of it again, as the user left it
      ctl.userConnect();
      async.elapse(const Duration(seconds: 3));
      expect(ctl.state, isA<Live>());
      expect(r.audio.last.monitor, isTrue);
      expect(r.audio.anyOpen, isTrue);
      ctl.userDisconnect();
      async.elapse(const Duration(seconds: 8));
      r.expectNothingRuns(async, when: 'after the second Disconnect');
      ctl.dispose();
    });
  });

  test('unplugged: Through PC closes at once; the status says Unplugged; replugged it comes back', () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      ctl.userConnect();
      async.elapse(const Duration(seconds: 3));
      expect(r.audio.anyOpen, isTrue);
      r.usb.present = false;
      r.usb.transports.last.unplug();
      async.elapse(const Duration(milliseconds: 200));
      expect(ctl.status, 'Unplugged');
      expect(r.audio.anyOpen, isFalse, reason: 'no Striso, no Through PC');
      expect(ctl.session.resources.has(Res.presence), isTrue, reason: 'it waits for the Striso to come back');
      r.usb.present = true;
      async.elapse(const Duration(seconds: 7));
      expect(ctl.state, isA<Live>());
      expect(r.audio.anyOpen, isTrue);
      ctl.userDisconnect();
      async.elapse(const Duration(seconds: 8));
      r.expectNothingRuns(async);
      ctl.dispose();
    });
  });

  test('Virtual: its output and MIDI run only while it is live; Disconnect stops them all', () {
    fakeAsync((async) {
      final r = Rig(through: false);
      final ctl = r.ctl;
      r.midi.plug('ls', name: 'LinnStrument MIDI');
      ctl.midi!.select('ls', true);
      ctl.start();
      ctl.playVirtual();
      async.elapse(const Duration(seconds: 3));
      expect(ctl.state, isA<Live>());
      expect(ctl.mode, Mode.virtual);
      expect(r.audio.last.outputOnly, isTrue, reason: 'Virtual plays to the output with Through PC off');
      expect(r.audio.anyOpen, isTrue);
      expect(r.usb.open, 0, reason: 'Virtual holds no USB session');
      expect(ctl.midi!.running, isTrue);
      expect(r.midi.devices().firstWhere((d) => d.id == 'ls').open, isTrue);
      expect(ctl.soundLine, contains('input: LinnStrument MIDI'));
      ctl.userDisconnect();
      async.elapse(const Duration(seconds: 8));
      r.expectNothingRuns(async, when: 'after Virtual');
      ctl.dispose();
    });
  });

  test('switching modes is a full teardown: Striso to Virtual leaves no USB, no input; and back', () {
    fakeAsync((async) {
      final r = Rig();
      final ctl = r.ctl;
      ctl.start();
      ctl.userConnect();
      async.elapse(const Duration(seconds: 3));
      expect(r.audio.last.monitor, isTrue);
      ctl.setMode(Mode.virtual);
      async.elapse(const Duration(seconds: 3));
      expect(ctl.mode, Mode.virtual);
      expect(ctl.state, isA<Live>());
      expect(r.usb.open, 0, reason: 'the Striso session ended');
      expect(r.audio.last.outputOnly, isTrue);
      expect(r.audio.last.input, '', reason: 'the Striso\'s audio input is closed');
      ctl.setMode(Mode.striso);
      async.elapse(const Duration(seconds: 3));
      expect(ctl.mode, Mode.striso);
      expect(r.usb.open, 1);
      expect(r.audio.last.monitor, isTrue);
      ctl.userDisconnect();
      async.elapse(const Duration(seconds: 8));
      r.expectNothingRuns(async);
      ctl.dispose();
    });
  });
}
