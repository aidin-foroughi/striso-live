// The Through PC state machine against the fake backend on a fake clock: finding the Striso,
// replugs, older firmware, choices, output trouble, macOS permission and recording.
import 'dart:io';

import 'package:striso_audio/striso_audio.dart';
import 'package:test/test.dart';

class Rig {
  final fake = FakeAudioBackend();
  late final ThroughPc pc;
  DateTime now = DateTime(2026, 10, 23, 14, 2, 11);
  bool board = true;
  final saved = <AudioPrefs>[];
  final logs = <String>[];
  late final Directory dir;

  Rig({AudioPrefs prefs = const AudioPrefs(), void Function(FakeAudioBackend)? setup, bool windows = true, AutoTiming timing = const AutoTiming()}) {
    setup?.call(fake);
    dir = Directory.systemTemp.createTempSync('striso_audio_test');
    pc = ThroughPc(
      backend: fake,
      prefs: prefs,
      boardOnUsb: () => board,
      onPrefs: saved.add,
      log: logs.add,
      clock: () => now,
      recordingsDir: () => '${dir.path}${Platform.pathSeparator}Striso Live Recordings',
      windows: windows,
      autoTiming: timing,
    );
  }

  /// Plays for [seconds]: 50 ms ticks, the input at [level] (0: quiet) moving the fake's clock.
  void play(double seconds, {double level = 0}) {
    for (var t = 0; t < seconds * 1000; t += 50) {
      now = now.add(const Duration(milliseconds: 50));
      fake.run(2400, level: level);
      pc.tick();
    }
  }

  /// Ticks every 50 ms for [ms].
  void run(int ms) {
    for (var t = 0; t < ms; t += 50) {
      now = now.add(const Duration(milliseconds: 50));
      pc.tick();
    }
  }

  void dispose() {
    pc.dispose();
    dir.deleteSync(recursive: true);
  }
}

const striso = FakeAudioBackend.striso;

void main() {
  group('pickInput', () {
    test('the USB VID/PID match wins over names', () {
      final l = [const AudioDevice('Striso Synth (an old name)'), const AudioDevice('Line In (USB Audio Device)', isStriso: true)];
      expect(pickInput(l, null)!.name, 'Line In (USB Audio Device)');
    });
    test('by name: "Striso Synth" in any case, then any Striso', () {
      expect(pickInput([const AudioDevice('Microphone (Yeti)'), const AudioDevice('Line (STRISO SYNTH)')], null)!.name, 'Line (STRISO SYNTH)');
      expect(pickInput([const AudioDevice('Striso MIDI'), const AudioDevice('Line (Striso Synth)')], null)!.name, 'Line (Striso Synth)');
      expect(pickInput([const AudioDevice('Microphone'), const AudioDevice('Striso')], null)!.name, 'Striso');
    });
    test('no Striso: nothing (never another microphone)', () {
      expect(pickInput([const AudioDevice('Microphone (USB Audio)', isDefault: true)], null), isNull);
      expect(pickInput(const [], null), isNull);
    });
    test('a chosen input by its exact name, or nothing', () {
      final l = [const AudioDevice('Microphone (USB Audio)'), striso];
      expect(pickInput(l, 'Microphone (USB Audio)')!.name, 'Microphone (USB Audio)');
      expect(pickInput(l, 'Microphone'), isNull);
    });
  });

  group('AudioPrefs', () {
    test('defaults: off, the Striso, the default output, Auto, -6 dB, exclusive input, exclusive output (wired)', () {
      const p = AudioPrefs();
      expect([p.through, p.input, p.output, p.period, p.gainDb, p.exclusive, p.exclusiveOutput], [false, null, null, AudioPrefs.auto, -6, true, true]);
      expect(p.isAuto, isTrue);
    });
    test('settings from before Auto: Auto and exclusive output; from now on what was chosen', () {
      final old = AudioPrefs.fromJson({'through': true, 'period': 64, 'exclusiveOutput': false});
      expect([old.period, old.exclusiveOutput, old.through], [AudioPrefs.auto, true, true]);
      final v2 = AudioPrefs.fromJson({'v': 2, 'period': 64, 'exclusiveOutput': false});
      expect([v2.period, v2.exclusiveOutput], [64, false]);
      final mem = AudioPrefs.fromJson({
        'v': 2,
        'auto': {
          'dock|exclusive': {'stable': 128, 'failed': 64, 'failedAt': 1000, 'floor': 9999},
          7: 'nonsense',
        },
      });
      expect(mem.autoMemory.keys, ['dock|exclusive']);
      expect(mem.autoMemory['dock|exclusive'], AutoMemory(stable: 128, failed: 64, failedAt: DateTime.fromMillisecondsSinceEpoch(1000)));
      expect(AudioPrefs.fromJson(mem.toJson()), mem);
    });
    test('JSON round trip', () {
      const p = AudioPrefs(
        through: true,
        input: 'Line (X)',
        output: 'Speakers (Y)',
        period: 64,
        gainDb: -12.5,
        exclusive: false,
        exclusiveOutput: true,
      );
      expect(AudioPrefs.fromJson(p.toJson()), p);
      expect(AudioPrefs.fromJson(const AudioPrefs().toJson()), const AudioPrefs());
    });
    test('bad values from disk fall back', () {
      final p = AudioPrefs.fromJson({'v': 2, 'through': 'yes', 'period': 100, 'gainDb': 50, 'input': '', 'exclusive': 0});
      expect([p.through, p.period, p.gainDb, p.input, p.exclusive], [false, AudioPrefs.auto, AudioPrefs.maxDb, null, true]);
      expect(AudioPrefs.fromJson('nonsense'), const AudioPrefs());
      expect(AudioPrefs.fromJson(null), const AudioPrefs());
    });
    test('copyWith clears a choice with null', () {
      const p = AudioPrefs(input: 'A', output: 'B');
      expect(p.copyWith(input: null).input, isNull);
      expect(p.copyWith(through: true).input, 'A');
    });
    test('gain: dB to linear, the bottom is silence', () {
      expect(gainOf(0), 1);
      expect(gainOf(-6), closeTo(0.501, 0.001));
      expect(gainOf(6), closeTo(1.995, 0.001));
      expect(gainOf(AudioPrefs.minDb), 0);
    });
  });

  test('recording names have no colons', () {
    expect(recordingName(DateTime(2026, 1, 2, 3, 4, 5)), 'Striso 2026-01-02 03.04.05.wav');
  });

  group('ThroughPc', () {
    late Rig r;
    tearDown(() => r.dispose());

    test('off by default: the audio system is not even started', () {
      r = Rig();
      r.run(500);
      expect(r.pc.state, ThroughState.off);
      expect(r.fake.inited, isFalse);
      expect(r.fake.configs, isEmpty);
    });

    test('turning on finds the Striso by VID/PID and plays it to the default output', () {
      r = Rig();
      r.pc.setThrough(true);
      r.run(300);
      expect(r.fake.last, AudioConfig(run: true, input: striso.name, output: '', period: AutoBuffer.safe, monitor: true, exclusive: true, exclusiveOutput: true));
      expect(r.pc.state, ThroughState.running);
      expect(r.pc.playing, isTrue);
      expect(r.pc.message, contains('Playing through the computer'));
      expect(r.pc.message, contains('48 kHz'));
      expect(r.pc.message, contains('24-bit'));
      expect(r.pc.liveLine, 'exclusive output');
      expect(r.pc.dropoutLine, 'no dropouts in the last minute');
      expect(r.pc.tone, Tone.ok);
      expect(r.saved.last.through, isTrue);
      expect(r.fake.gain, closeTo(gainOf(-6), 1e-9));
      r.pc.setGainDb(-20);
      r.run(50);
      expect(r.fake.gain, closeTo(0.1, 1e-9));
    });

    test('remembered on: starts by itself', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      expect(r.pc.state, ThroughState.running);
      expect(r.saved, isEmpty);
    });

    test('turning off closes everything', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      r.pc.setThrough(false);
      r.run(100);
      expect(r.fake.last.run, isFalse);
      expect(r.pc.state, ThroughState.off);
      expect(r.saved.last.through, isFalse);
    });

    test('a replug: missing while gone, back by itself once listed again', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      final sent = r.fake.configs.length;
      r.fake.unplug();
      r.run(5000);
      expect(r.pc.state, ThroughState.missing);
      expect(r.pc.tone, Tone.problem);
      expect(r.pc.message, contains('comes back by itself'));
      expect(r.fake.configs.length, sent, reason: 'nothing to open while the input is not listed');
      r.fake.plug();
      r.run(2500);
      expect(r.pc.state, ThroughState.running);
      expect(r.fake.configs.length, sent + 1);
      expect(r.fake.last, r.fake.configs[sent - 1]);
    });

    test('lost but still listed (the board restarting): retried until it opens', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      r.fake.failOpen = true;
      r.fake.lose();
      r.run(2000);
      expect(r.pc.state, ThroughState.failed);
      final n = r.fake.configs.length;
      r.run(3500);
      expect(r.fake.configs.length, greaterThan(n), reason: 'retries every 3 s');
      r.fake.failOpen = false;
      r.run(3500);
      expect(r.pc.state, ThroughState.running);
    });

    test('the board on USB without an audio input: older firmware, said plainly', () {
      r = Rig(setup: (f) => f.inputs = [const AudioDevice('Microphone (USB Audio)', isDefault: true)]);
      r.pc.setThrough(true);
      r.run(3000);
      expect(r.pc.state, ThroughState.searching, reason: 'Windows needs a moment to add the endpoint');
      r.run(5000);
      expect(r.pc.state, ThroughState.noUsbAudio);
      expect(r.pc.message, contains('no USB audio'));
      expect(r.fake.configs, isEmpty, reason: 'never another microphone');
      // the board goes away: just looking
      r.board = false;
      r.run(200);
      expect(r.pc.state, ThroughState.searching);
      expect(r.pc.message, contains('plug in the Striso'));
    });

    test('a chosen input that is not connected', () {
      r = Rig();
      r.pc.setInput('Line (Other Interface)');
      r.pc.setThrough(true);
      r.run(500);
      expect(r.pc.state, ThroughState.missing);
      expect(r.pc.message, contains('“Line (Other Interface)” is not connected'));
      r.pc.setInput('Microphone (USB Audio)');
      r.run(200);
      expect(r.fake.last.input, 'Microphone (USB Audio)');
      expect(r.pc.state, ThroughState.running);
    });

    test('a chosen output that is gone: the default plays, with a note', () {
      r = Rig(prefs: const AudioPrefs(through: true, output: 'Headphones (Bluetooth)'));
      r.run(300);
      expect(r.fake.last.output, '');
      expect(r.pc.state, ThroughState.running);
      expect(r.pc.outputNote, contains('not connected: playing to the default output'));
      r.pc.setOutput('Headphones (USB)');
      r.run(100);
      expect(r.fake.last.output, 'Headphones (USB)');
      expect(r.pc.outputNote, isNull);
    });

    test('the output fails: the input keeps running, the output is retried', () {
      r = Rig(prefs: const AudioPrefs(through: true), setup: (f) => f.failOutput = true);
      r.run(300);
      expect(r.pc.state, ThroughState.running);
      expect(r.pc.playing, isFalse);
      expect(r.pc.outputNote, contains('would not open'));
      expect(r.pc.tone, Tone.problem);
      r.fake.failOutput = false;
      r.run(2500);
      expect(r.pc.playing, isTrue);
      expect(r.pc.outputNote, isNull);
      r.fake.loseOutput();
      r.run(100);
      expect(r.pc.outputNote, contains('went away'));
      r.run(2500);
      expect(r.pc.playing, isTrue);
    });

    test('period and exclusive mode reach the native side', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      r.pc.setPeriod(64);
      r.pc.setExclusive(false);
      r.pc.setExclusiveOutput(false);
      r.run(100);
      expect(r.fake.last.exclusiveOutput, isFalse, reason: 'turned off: shared');
      r.pc.setExclusiveOutput(true);
      r.run(100);
      expect(r.fake.last.period, 64);
      expect(r.fake.last.exclusive, isFalse);
      expect(r.fake.last.exclusiveOutput, isTrue);
      expect(r.pc.st.playbackExclusive, isTrue);
      expect(r.pc.message, contains('float'), reason: 'shared mode gives the mix format');
    });

    test('macOS: asks for permission, opens once allowed', () {
      r = Rig(setup: (f) => f.mic = Mic.undetermined);
      r.pc.setThrough(true);
      r.run(300);
      expect(r.pc.state, ThroughState.permission);
      expect(r.pc.message, contains('macOS is asking'));
      r.fake.setMic(Mic.authorized);
      r.run(300);
      expect(r.pc.state, ThroughState.running);
    });

    test('macOS: denied is said plainly and not hammered', () {
      r = Rig(setup: (f) => f.mic = Mic.denied);
      r.pc.setThrough(true);
      r.run(500);
      expect(r.pc.state, ThroughState.denied);
      expect(r.pc.message, contains('Privacy & Security › Microphone'));
      final n = r.fake.configs.length;
      r.run(10000);
      expect(r.fake.configs.length, n);
    });

    test('recording with Through PC off: the input only, a timestamped WAV, closed after', () {
      r = Rig();
      r.pc.startRecording();
      r.run(200);
      expect(r.fake.last, AudioConfig(run: true, input: striso.name, period: AutoBuffer.safe, monitor: false, exclusive: true, exclusiveOutput: true));
      expect(r.pc.recording, isTrue);
      final path = r.pc.recordingPath!;
      expect(path, endsWith('${Platform.pathSeparator}Striso Live Recordings${Platform.pathSeparator}Striso 2026-10-23 14.02.11.wav'));
      expect(Directory('${r.dir.path}${Platform.pathSeparator}Striso Live Recordings').existsSync(), isTrue);
      r.fake.run(48000);
      r.run(50);
      expect(r.pc.recordSeconds, 1.0);
      r.pc.stopRecording();
      r.run(200);
      expect(r.pc.recording, isFalse);
      expect(r.pc.lastRecording, path);
      expect(r.pc.recordNote, isNull);
      expect(r.fake.last.run, isFalse, reason: 'nothing wants the input any more');
    });

    test('recording while playing keeps playing after', () {
      r = Rig(prefs: const AudioPrefs(through: true));
      r.run(300);
      final n = r.fake.configs.length;
      r.pc.startRecording();
      r.run(100);
      expect(r.fake.configs.length, n, reason: 'the running input records as it is');
      r.fake.run(4800);
      r.pc.stopRecording();
      r.run(100);
      expect(r.pc.lastRecording, isNotNull);
      expect(r.pc.state, ThroughState.running);
      expect(r.fake.last.run, isTrue);
    });

    test('a recording ends when the input goes away, and says so', () {
      r = Rig();
      r.pc.startRecording();
      r.run(200);
      r.fake.run(9600);
      r.fake.lose();
      r.run(100);
      expect(r.pc.recording, isFalse);
      expect(r.pc.lastRecording, isNotNull);
      expect(r.pc.recordNote, contains('went away'));
    });

    test('dispose stops a recording and shuts the native side down', () {
      r = Rig();
      r.pc.startRecording();
      r.run(200);
      r.pc.dispose();
      expect(r.fake.recordStops, 1);
      expect(r.fake.shutdownCalled, isTrue);
    });

    test('no library, or an audio system that does not start: unavailable', () {
      r = Rig();
      final none = ThroughPc(backend: null);
      none.setThrough(true);
      none.tick();
      expect(none.state, ThroughState.unavailable);
      expect(none.message, contains('missing from this build'));
      final bad = FakeAudioBackend()..initOk = false;
      final pc = ThroughPc(backend: bad, prefs: const AudioPrefs(through: true));
      pc.tick();
      expect(pc.state, ThroughState.unavailable);
      expect(pc.available, isFalse);
      pc.dispose();
    });
  });
}
