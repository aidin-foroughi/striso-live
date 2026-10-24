// MIDI input: MidiInputs (the choice, hot-plug, "in use", stop) against FakeMidiBackend on
// fake_async's clock, and the native binding (striso_midi.h) when the library is built: init and
// the list (opens nothing), sa_midi_inject through the recording test sink, the monitor, and the
// Dart parser of the fake against the native one on a random byte stream. No MIDI device needed:
//   cmake -S native -B ../../build/striso_audio && cmake --build ../../build/striso_audio --config Release
// (Windows; macOS: sh native/build_macos.sh), or STRISO_AUDIO_LIB=<path to the library>.
import 'dart:io';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:test/test.dart';

String? findLib() {
  final env = Platform.environment['STRISO_AUDIO_LIB'];
  final c = [
    if (env != null && env.isNotEmpty) env,
    if (Platform.isWindows) ...['../../build/striso_audio/Release/striso_audio.dll', '../../build/windows/x64/runner/Release/striso_audio.dll'],
    if (Platform.isMacOS) 'native/build/macos/libstriso_audio.dylib',
    if (Platform.isLinux) '../../build/striso_audio/libstriso_audio.so',
  ];
  for (final p in c) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

class Rig {
  final FakeAsync async;
  final fake = FakeMidiBackend();
  final prefs = <Map<String, Object?>>[];
  final logs = <String>[];
  late final MidiInputs inputs;
  var notified = 0;

  Rig(this.async, {Iterable<String> chosen = const []}) {
    fake.clock = () => async.elapsed.inMicroseconds;
    inputs = MidiInputs(fake, chosen: chosen, onPrefs: prefs.add, log: logs.add);
    inputs.addListener(() => notified++);
  }

  void seconds(double s) => async.elapse(Duration(microseconds: (s * 1e6).round()));
  MidiInputStatus st(String id) => inputs.status(id)!;
}

void main() {
  group('MidiInputs on the fake', () {
    test('nothing chosen: nothing opened; select opens at once and is persisted', () {
      fakeAsync((async) {
        final r = Rig(async);
        r.fake.plug('A', name: 'LinnStrument');
        r.fake.plug('B', name: 'Striso');
        expect(r.inputs.start(), isTrue);
        expect(r.fake.calls.where((c) => c.startsWith('open')), isEmpty);
        expect(r.inputs.devices.map((d) => '${d.id}:${d.state.name}'), ['A:off', 'B:off']);

        r.inputs.select('A', true);
        expect(r.fake.calls, contains('open A'));
        expect(r.st('A').state, MidiInputState.open);
        expect(r.st('A').text, 'open');
        expect(r.prefs.last, {
          'inputs': [
            {'id': 'A', 'name': 'LinnStrument'},
          ],
        });
        expect(r.notified, greaterThan(0));

        // what the open input plays reaches the sink as USB-MIDI packets, exactly
        r.inputs.setSink(0x1234, 0x5678);
        expect(r.fake.sinkFn, 0x1234);
        r.fake.play('A', [0x90, 60, 100, 0xF8, 62, 0, 0xF0, 1, 2, 0xF7, 0xD0, 0x22]);
        expect(r.fake.sinkCalls, [
          [0x09, 0x90, 60, 100, 0x09, 0x90, 62, 0, 0x0D, 0xD0, 0x22, 0],
        ]);
        expect(r.fake.play('B', [0x90, 60, 100]), 0, reason: 'B is not chosen: closed');

        r.inputs.select('A', false);
        expect(r.fake.calls.last, 'close A');
        expect(r.st('A').state, MidiInputState.off);
        expect(r.prefs.last, {'inputs': <Object?>[]});
        r.inputs.stop();
      });
    });

    test('unplugged and back: not connected, then reopened by the next refresh', () {
      fakeAsync((async) {
        final r = Rig(async, chosen: ['A']);
        r.fake.plug('A', name: 'Striso');
        r.inputs.start();
        expect(r.st('A').state, MidiInputState.open);
        r.inputs.setSink(1, 2);

        r.fake.unplug('A');
        r.seconds(1);
        expect(r.st('A').state, MidiInputState.notConnected);
        expect(r.st('A').text, 'not connected');
        expect(r.st('A').name, 'Striso', reason: 'the name is kept while it is away');
        final gone = r.fake.devices().singleWhere((d) => d.id == 'A');
        expect(gone.present, isFalse);
        expect(gone.error, midiErrGone);

        r.seconds(3);
        expect(r.fake.calls.where((c) => c == 'open A').length, 1, reason: 'not retried while away');

        r.fake.plug('A', name: 'Striso');
        r.seconds(1);
        expect(r.fake.calls.where((c) => c == 'open A').length, 2);
        expect(r.st('A').state, MidiInputState.open);
        r.fake.play('A', [0xB0, 74, 64]);
        expect(r.fake.sinkCalls.last, [0x0B, 0xB0, 74, 64]);
        r.inputs.stop();
      });
    });

    test('in use by another program: says so, retries every second, opens when freed', () {
      fakeAsync((async) {
        final r = Rig(async, chosen: ['K']);
        r.fake.plug('K', name: 'Keyboard');
        r.fake.inUse.add('K');
        r.inputs.start();
        expect(r.st('K').state, MidiInputState.inUse);
        expect(r.st('K').text, 'in use by another program');
        r.seconds(2);
        expect(r.fake.calls.where((c) => c == 'open K').length, 3);
        expect(r.logs.where((l) => l.contains('in use')).length, 1, reason: 'logged once, not every retry');

        r.fake.inUse.remove('K');
        r.seconds(1);
        expect(r.st('K').state, MidiInputState.open);

        r.fake.openErrors['X'] = midiErrOpen;
        r.fake.plug('X', name: 'Broken');
        r.inputs.select('X', true);
        expect(r.st('X').state, MidiInputState.error);
        expect(r.st('X').text, midiErrorText(midiErrOpen));
        r.inputs.stop();
      });
    });

    test('a chosen input that is not there is listed as not connected', () {
      fakeAsync((async) {
        final r = Rig(async);
        r.inputs.select('Z', true);
        expect(r.st('Z').state, MidiInputState.stopped);
        r.inputs.start();
        expect(r.inputs.devices.single.id, 'Z');
        expect(r.st('Z').state, MidiInputState.notConnected);
        r.inputs.stop();
      });
    });

    test('stop closes everything and leaves no timer', () {
      fakeAsync((async) {
        final r = Rig(async, chosen: ['A', 'B']);
        r.fake.plug('A');
        r.fake.plug('B');
        r.inputs.start();
        expect(async.periodicTimerCount, 1);
        expect(r.fake.devices().where((d) => d.open).length, 2);

        r.inputs.stop();
        expect(r.fake.calls.last, 'closeAll');
        expect(r.fake.devices().where((d) => d.open), isEmpty);
        expect(async.periodicTimerCount, 0);
        expect(async.pendingTimers, isEmpty);
        final n = r.fake.refreshes;
        r.seconds(10);
        expect(r.fake.refreshes, n, reason: 'nothing runs while stopped');
        expect(r.st('A').state, MidiInputState.stopped);

        // start again: reopened
        r.inputs.start();
        expect(r.fake.devices().where((d) => d.open).length, 2);
        r.inputs.dispose();
        expect(async.pendingTimers, isEmpty);
        expect(r.fake.inited, isFalse);
      });
    });

    test('no MIDI system: start says so and runs nothing', () {
      fakeAsync((async) {
        final r = Rig(async, chosen: ['A']);
        r.fake.available = false;
        expect(r.inputs.start(), isFalse);
        expect(r.inputs.available, isFalse);
        expect(async.pendingTimers, isEmpty);
        expect(r.st('A').state, MidiInputState.stopped);
        expect(r.st('A').text, midiErrorText(midiErrSystem));
      });
    });

    test('activity: messages in the last second, per input and total', () {
      fakeAsync((async) {
        final r = Rig(async, chosen: ['A', 'B']);
        r.fake.plug('A');
        r.fake.plug('B');
        r.inputs.start();
        r.seconds(0.5);
        for (var i = 0; i < 10; i++) {
          r.fake.play('A', [0xA0, 60, i]);
        }
        r.fake.play('B', [0x90, 60, 1, 0x80, 60, 0]);
        r.seconds(0.5); // the tick at 1 s
        expect(r.inputs.activityOf('A'), 10);
        expect(r.inputs.activityOf('B'), 2);
        expect(r.inputs.activity, 12);
        expect(r.st('A').activity, 10);
        expect(r.inputs.recent.length, 12);
        r.seconds(1);
        expect(r.inputs.activity, 0, reason: 'quiet for a second');
        r.inputs.stop();
      });
    });

    test('prefs: toJson and back, a plain list too', () {
      final fake = FakeMidiBackend();
      final a = MidiInputs(fake, chosen: ['b', 'a'], names: {'a': 'Alpha'});
      expect(a.toJson(), {
        'inputs': [
          {'id': 'a', 'name': 'Alpha'},
          {'id': 'b'},
        ],
      });
      expect(MidiInputs.fromJson(fake, a.toJson()).chosen, {'a', 'b'});
      expect(MidiInputs.fromJson(fake, ['x', 'y']).chosen, {'x', 'y'});
      expect(MidiInputs.fromJson(fake, null).chosen, isEmpty);
      expect(MidiInputs.fromJson(fake, a.toJson()).status('a')!.name, 'Alpha');
    });

    test('the fake parser: running status, real time, sysex, 2-byte messages, velocity 0', () {
      final p = MidiParser();
      expect(p.feed([0x90, 60, 100, 62, 0]), [9, 0x90, 60, 100, 9, 0x90, 62, 0]);
      expect(p.feed([0xF8, 0xFE]), isEmpty);
      expect(p.feed([0xF0, 1, 2, 0xF7, 64, 1]), isEmpty, reason: 'sysex cancels running status');
      expect(p.feed([0xC2, 5, 0xE0, 0, 0x40]), [0xC, 0xC2, 5, 0, 0xE, 0xE0, 0, 0x40]);
      expect(p.feed([0xF2, 1, 2, 0xB0]), isEmpty);
      expect(p.feed([7]), isEmpty);
      expect(p.feed([0x7F]), [0xB, 0xB0, 7, 0x7F]);
    });
  });

  group('native', () {
    final path = findLib();
    final skip = path == null ? 'striso_audio is not built (see the header of this file)' : null;
    late NativeMidiBackend m;

    setUpAll(() {
      if (path == null) return;
      m = NativeMidiBackend.of(StrisoAudioLib.load(explicit: path))!;
    });

    test('init and list the system inputs (opens nothing)', () {
      expect(m.init(), isTrue);
      expect(m.init(), isTrue, reason: 'idempotent');
      final g = m.refresh();
      expect(m.refresh(), g, reason: 'nothing changed');
      final list = m.devices();
      // ignore: avoid_print
      print('MIDI inputs: ${list.isEmpty ? 'none' : list.join(', ')}');
      expect(list.where((d) => d.open && !d.isVirtual), isEmpty);
      expect(m.open('dart test: no such input'), midiErrNotFound);
    }, skip: skip);

    test('inject without a device: exact packets to the sink, the monitor, the virtual device', () {
      m.init();
      m.setSink(m.testSinkAddress, 0);
      m.testSinkRead();
      m.events();
      final n = m.inject('dart-test', [0x90, 60, 100, 0xF8, 62, 0, 0xF0, 1, 2, 0xF7, 0xC3, 5, 0xFE]);
      expect(n, 3);
      expect(m.testSinkRead(), [0x09, 0x90, 60, 100, 0x09, 0x90, 62, 0, 0x0C, 0xC3, 5, 0]);
      final d = m.devices().singleWhere((d) => d.id == 'dart-test');
      expect(d.isVirtual, isTrue);
      expect(d.open, isTrue);
      expect(d.messages, 3);
      final ev = m.events();
      expect(ev.map((e) => e.bytes), [
        [0x90, 60, 100],
        [0x90, 62, 0],
        [0xC3, 5],
      ]);
      expect(ev.every((e) => e.device == d.slot), isTrue);
      expect(ev.last.tUs, d.lastUs);
      expect(d.lastUs, inInclusiveRange(1, m.clockUs()));

      // MidiInputs sees it as an open (virtual) input
      final inputs = MidiInputs(m);
      inputs.start();
      expect(inputs.status('dart-test')!.state, MidiInputState.open);
      inputs.stop();

      // with no sink: not delivered
      m.setSink(0, 0);
      m.inject('dart-test', [0xB0, 1, 2]);
      expect(m.testSinkRead(), isEmpty);
      m.close('dart-test');
      expect(m.devices().where((d) => d.id == 'dart-test'), isEmpty);
    }, skip: skip);

    test('the fake parser equals the native one on 20000 random bytes', () {
      m.init();
      m.setSink(m.testSinkAddress, 0);
      m.testSinkRead();
      final rnd = Random(7);
      // mostly data, some statuses of every kind, real time and sysex
      final bytes = [
        for (var i = 0; i < 20000; i++)
          switch (rnd.nextInt(10)) {
            < 6 => rnd.nextInt(0x80),
            < 8 => 0x80 + rnd.nextInt(0x70),
            8 => 0xF0 + rnd.nextInt(0x10),
            _ => 0xF8,
          },
      ];
      final want = MidiParser().feed(bytes);
      final got = <int>[];
      for (var i = 0; i < bytes.length; i += 500) {
        m.inject('dart-cross', bytes.sublist(i, min(i + 500, bytes.length)));
        got.addAll(m.testSinkRead());
      }
      expect(want.length, greaterThan(1000));
      expect(got, want);
      m.setSink(0, 0);
      m.close('dart-cross');
      m.events();
      m.shutdown();
      expect(m.devices(), isEmpty);
    }, skip: skip);
  });
}
