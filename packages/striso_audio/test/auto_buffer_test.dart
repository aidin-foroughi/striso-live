// Auto buffering: the policy on its own (a clock and a dropout counter), then through ThroughPc on
// the fake backend: per-output memory, quiet moments, the device minimum, exclusive output on wired
// outputs only, and dropouts counted by side.

import 'package:striso_audio/striso_audio.dart';
import 'package:test/test.dart';

import 'through_pc_test.dart' show Rig;

void main() {
  group('AutoBuffer (the policy alone)', () {
    late AutoBuffer a;
    late DateTime now;
    var mem = AutoMemory.none;
    var drops = 0;
    final notes = <String>[];

    /// [seconds] of ticks at 50 ms; playing while [playing]; quiet input unless [loud].
    void go(double seconds, {bool playing = true, bool loud = false, int buffer = 0, String key = 'dock|exclusive'}) {
      for (var t = 0; t < seconds * 1000; t += 50) {
        now = now.add(const Duration(milliseconds: 50));
        final s = a.step(now: now, key: key, mem: mem, playing: playing, dropouts: drops, level: loud ? 0.3 : 0, deviceBuffer: buffer > 0 ? buffer : a.current);
        if (s.remember != null) mem = s.remember!;
        if (s.note != null) notes.add(s.note!);
      }
    }

    setUp(() {
      a = AutoBuffer();
      now = DateTime(2026, 10, 23, 12);
      mem = AutoMemory.none;
      drops = 0;
      notes.clear();
    });

    test('starts safe on an unknown output, tightens every 20 s of clean playing', () {
      go(0.05);
      expect(a.current, AutoBuffer.safe);
      go(19);
      expect(a.current, 256, reason: 'not yet 20 s clean (2 s grace first)');
      go(4);
      expect(a.current, 128);
      go(23);
      expect(a.current, 64);
      go(100);
      expect(a.current, 64, reason: 'the smallest step');
      expect(mem.stable, 64, reason: 'a minute clean: remembered');
    });

    test('backs off one step at the first dropout and never tries that size again', () {
      go(0.05);
      go(23);
      go(23);
      expect(a.current, 64);
      go(3); // past the priming grace at 64
      drops++; // a dropout at 64
      go(0.1, loud: true);
      expect(a.pending, 128);
      expect(a.current, 64, reason: 'waits for a quiet moment ...');
      go(3.1, loud: true);
      expect(a.current, 128, reason: '... at most 3 s');
      expect(mem.failed, 64);
      expect(mem.stable, isNull, reason: 'what was stable dropped out');
      drops = 0; // the reopen restarts the native counter
      go(200);
      expect(a.current, 128, reason: 'never 64 again on this output');
      expect(mem.stable, 128);
      expect(notes.where((n) => n.contains('backing off')), hasLength(1));
    });

    test('a dropout during priming does not count; one after does', () {
      go(0.05);
      drops = 3; // while priming (2 s grace)
      go(1);
      expect(a.pending, isNull);
      go(2);
      drops = 4;
      go(0.1);
      expect(a.current, 512, reason: 'a quiet input: at once');
      expect(mem.failed, 256);
    });

    test('tightening waits for a quiet input (a change reopens the devices)', () {
      go(0.05);
      go(30, loud: true);
      expect(a.current, 256);
      expect(a.pending, 128);
      expect(a.phase, 'tightening');
      go(1);
      expect(a.current, 128);
    });

    test('remembered per output: starts at the stable size, stays above what failed', () {
      mem = AutoMemory(stable: 128, failed: 64, failedAt: DateTime(2026, 10, 22));
      go(0.05);
      expect(a.current, 128);
      go(60);
      expect(a.current, 128, reason: '64 failed a day ago');
      // another output: its own memory, safe start
      final other = AutoMemory.none;
      final s = a.step(now: now, key: 'speakers|shared', mem: other, playing: false, dropouts: 0, level: 0, deviceBuffer: 0);
      expect(s.period, AutoBuffer.safe);
    });

    test('a failed size is tried again after a week', () {
      mem = AutoMemory(stable: 128, failed: 64, failedAt: DateTime(2026, 10, 1));
      go(0.05);
      go(23);
      expect(a.current, 64);
    });

    test('the device minimum: a smaller request with the same device buffer goes back and is remembered', () {
      go(0.05);
      go(23, buffer: 144); // the device gives 144 frames whatever is asked below it
      expect(a.current, 128);
      go(3, buffer: 144);
      expect(mem.floor, 256, reason: '128 gave the same buffer as 256: no point below 256');
      expect(a.current, 256);
      go(60, buffer: 144);
      expect(a.current, 256);
    });

    test('the device minimum from the system: sizes below it are not tried (they give the minimum)', () {
      expect(AutoBuffer.floorOf(144), 128, reason: '64 and 128 both give 144 frames');
      expect(AutoBuffer.floorOf(48), 0);
      expect(AutoBuffer.floorOf(0), 0);
      go(0.05);
      for (var t = 0; t < 120 * 20; t++) {
        now = now.add(const Duration(milliseconds: 50));
        final s = a.step(now: now, key: 'dock|exclusive', mem: mem, playing: true, dropouts: 0, level: 0, deviceBuffer: a.current < 144 ? 144 : a.current, deviceMin: 144);
        if (s.remember != null) mem = s.remember!;
      }
      expect(a.current, 128);
      expect(mem.stable, 128);
      expect(mem.floor, isNull, reason: 'known from the system, not learned by a wasted reopen');
    });

    test('a failure at the largest size stays there and says so', () {
      mem = const AutoMemory(stable: 512);
      go(0.05);
      expect(a.current, 512);
      go(3);
      drops++;
      go(0.1);
      expect(a.current, 512);
      expect(notes.last, contains('the largest'));
    });
  });

  group('Auto through ThroughPc (fake backend)', () {
    late Rig r;
    tearDown(() => r.dispose());

    test('settles on the smallest clean size for the output and remembers it by device id', () {
      r = Rig(
        prefs: const AudioPrefs(through: true),
        setup: (f) {
          f.outputs = [const AudioDevice('Headphones (TBT200 Dock)', id: '{0.0.0.00000000}.{dock}', transport: AudioTransport.usb, isDefault: true)];
          f.stableFrom = {'': 128}; // the default output drops out below 128
        },
      );
      r.play(1);
      expect(r.fake.last.period, 256);
      expect(r.fake.last.exclusiveOutput, isTrue, reason: 'a wired output: exclusive');
      r.play(24);
      expect(r.fake.last.period, 128);
      r.play(20.5);
      expect(r.fake.last.period, 64);
      r.play(4);
      expect(r.fake.last.period, 128, reason: 'one dropout at 64 after its priming: back one step');
      expect(r.fake.configs.where((c) => c.run).map((c) => c.period).toList(), [256, 128, 64, 128]);
      expect(r.pc.dropoutsLastMinute()[DropSide.output], greaterThan(0));
      expect(r.logs.where((l) => l.contains('dropout: ring empty')), isNotEmpty, reason: 'every dropout is logged with its cause');
      r.play(70);
      expect(r.fake.last.period, 128);
      final key = '{0.0.0.00000000}.{dock}|exclusive';
      expect(r.saved.last.autoMemory[key]?.stable, 128);
      expect(r.saved.last.autoMemory[key]?.failed, 64);

      // the next start: straight to 128
      final again = Rig(prefs: r.saved.last, setup: (f) => f.outputs = r.fake.outputs);
      again.play(1);
      expect(again.fake.configs.where((c) => c.run).first.period, 128);
      again.dispose();
    });

    test('a manual size is used as it is', () {
      r = Rig(prefs: const AudioPrefs(through: true, period: 64), setup: (f) => f.stableFrom = {'': 128});
      r.play(60);
      expect(r.fake.configs.where((c) => c.run).map((c) => c.period).toSet(), {64});
    });

    test('Bluetooth output: shared, and a one-line note', () {
      r = Rig(
        prefs: const AudioPrefs(through: true),
        setup: (f) => f.outputs = [const AudioDevice('Headphones (WH-1000XM4)', id: 'bt', transport: AudioTransport.bluetooth, isDefault: true)],
      );
      r.play(1);
      expect(r.fake.last.exclusiveOutput, isFalse);
      expect(r.pc.outputHint, 'Bluetooth adds ~150–250 ms. Use a wired output for playing.');
      expect(const AudioDevice('Speakers', id: r'SWD\MMDEVAPI\x\BTHENUM\{0000110b}').isBluetooth, isTrue);
      expect(const AudioDevice('AirPods Pro').isBluetooth, isTrue);
      expect(const AudioDevice('Speakers (Realtek)').isBluetooth, isFalse);
    });

    test('exclusive output held by another program: shared, with a quiet note', () {
      r = Rig(prefs: const AudioPrefs(through: true), setup: (f) => f.exclusiveBusy = true);
      r.play(1);
      expect(r.fake.last.exclusiveOutput, isTrue);
      expect(r.pc.st.playbackExclusive, isFalse);
      expect(r.pc.outputHint, 'Shared output: another program holds it exclusively.');
      expect(r.pc.playing, isTrue);
    });

    test('macOS: no exclusive mode', () {
      r = Rig(prefs: const AudioPrefs(through: true), windows: false);
      r.play(1);
      expect(r.fake.last.exclusiveOutput, isFalse);
    });

    test('dropouts by side in the last minute: board, input, output', () {
      r = Rig(prefs: const AudioPrefs(through: true, period: 128));
      r.play(3);
      r.fake.dropout(input: true);
      r.fake.dropout();
      r.play(0.1);
      r.pc.boardStats(const BoardAudioStats(sent: 2000, underruns: 2, overruns: 0, ringMin: 0, ringMax: 160, ringFiltered: 140));
      expect(r.pc.dropoutsLastMinute(), {DropSide.board: 2, DropSide.input: 1, DropSide.output: 1});
      expect(r.pc.liveLine, startsWith('dropouts: 4 in the last minute'));
      expect(r.pc.breakdown.usbMeasured, isTrue);
      expect(r.pc.breakdown.usb, closeTo(140 / 48 + 1, 1e-9));
      expect(r.logs.where((l) => l.contains('dropout on the board: 2 underruns')), hasLength(1));
      expect(r.logs.where((l) => l.contains('input late')), isNotEmpty);
      r.play(61);
      expect(r.pc.dropoutsLastMinute().values.every((n) => n == 0), isTrue);
      expect(r.pc.breakdown.usbMeasured, isFalse, reason: 'old board numbers: the estimate again');
    });

    test('the breakdown adds up', () {
      r = Rig(prefs: const AudioPrefs(through: true, period: 128));
      r.play(1);
      final b = r.pc.breakdown;
      expect(b.total, closeTo(b.input + b.ring + b.output + b.usb, 1e-9));
      expect(b.output, closeTo(128 / 48, 1e-6));
      expect(b.usb, closeTo(144 / 48 + 1, 1e-9), reason: 'no board numbers yet: its 3 ms target + the packet');
    });
  });
}
