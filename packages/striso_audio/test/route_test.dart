// The audio route the app's session sets: off opens nothing and lets the timer stop; input is
// Through PC and Record (the Striso's USB audio); source is the output alone for the virtual board.
import 'package:fake_async/fake_async.dart';
import 'package:striso_audio/striso_audio.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime(2026, 10, 24, 12);
  late FakeAsync fa;
  ThroughPc make(FakeAudioBackend fake, {AudioRoute route = AudioRoute.off, bool through = true}) =>
      ThroughPc(backend: fake, prefs: AudioPrefs(through: through), route: route, windows: true, clock: () => t0.add(fa.elapsed));

  test('off: Through PC on but nothing opens, no timer; input opens it; off closes it again', () {
    fakeAsync((async) {
      fa = async;
      final fake = FakeAudioBackend();
      final pc = make(fake)..start();
      async.elapse(const Duration(seconds: 2));
      expect(fake.last.run, isFalse);
      expect(fake.anyOpen, isFalse);
      expect(pc.ticking, isFalse);
      expect(async.periodicTimerCount, 0);
      pc.setRoute(AudioRoute.input);
      async.elapse(const Duration(seconds: 3));
      expect(pc.ticking, isTrue);
      expect(fake.last.run, isTrue);
      expect(fake.last.monitor, isTrue);
      expect(pc.playing, isTrue);
      pc.setRoute(AudioRoute.off);
      async.elapse(const Duration(milliseconds: 200));
      expect(fake.last.run, isFalse, reason: 'the devices are closed');
      expect(fake.anyOpen, isFalse);
      expect(pc.ticking, isFalse);
      expect(async.periodicTimerCount, 0);
      expect(pc.through, isTrue, reason: 'the choice stays for the next session');
      pc.dispose();
    });
  });

  test('a recording ends when the route leaves input; Record outside input says why', () {
    fakeAsync((async) {
      fa = async;
      final fake = FakeAudioBackend()..documents = '/tmp';
      final pc = make(fake, route: AudioRoute.input, through: false)..start();
      async.elapse(const Duration(seconds: 3));
      pc.setRoute(AudioRoute.off);
      async.elapse(const Duration(seconds: 1));
      expect(pc.recording, isFalse);
      pc.startRecording();
      expect(pc.recordNote, contains('connect the Striso'));
      pc.dispose();
    });
  });

  test('source: the output alone (exclusive on Windows), the granted mode, the source attached', () {
    fakeAsync((async) {
      fa = async;
      final fake = FakeAudioBackend();
      final pc = make(fake, route: AudioRoute.source, through: false)..start();
      async.elapse(const Duration(seconds: 3));
      expect(fake.last.run, isTrue);
      expect(fake.last.outputOnly, isTrue);
      expect(fake.last.monitor, isFalse);
      expect(fake.last.input, '');
      expect(pc.state, ThroughState.running);
      expect(pc.playing, isTrue);
      expect(pc.message, startsWith('Playing the virtual Striso'));
      expect(pc.grantedLine, startsWith('Output: '));
      expect(pc.setSource(123, 456), isTrue);
      expect(fake.sourceFn, 123);
      pc.setSource(0, 0);
      expect(fake.sourceFn, 0);
      pc.dispose();
    });
  });

  test('source: an output that will not open is retried and said so', () {
    fakeAsync((async) {
      fa = async;
      final fake = FakeAudioBackend()..failOutput = true;
      final pc = make(fake, route: AudioRoute.source)..start();
      async.elapse(const Duration(seconds: 1));
      expect(pc.state, ThroughState.failed);
      expect(pc.outputNote, contains('would not open'));
      final n = fake.configs.length;
      async.elapse(const Duration(seconds: 5));
      expect(fake.configs.length, greaterThan(n), reason: 'retried');
      fake.failOutput = false;
      async.elapse(const Duration(seconds: 3));
      expect(pc.state, ThroughState.running);
      pc.dispose();
    });
  });
}
