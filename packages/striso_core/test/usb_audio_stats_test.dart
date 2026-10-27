// StcU: the board's USB audio counters, parsed by their words (the firmware's reply is text), in
// the UAC1 firmware's layout and the UAC2 firmware's; Stct, the board's ring target. The client
// asking the board: packages/striso_virtual/test/usb_audio_test.dart.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

void main() {
  // as the UAC1 firmware's usb_audio.c prints it
  const uac1 = [
    'usb audio: streaming 48000 Hz 24 bit (alt 1), source synth',
    'since last U: packets sent 2001 missed 3 built 2001 (47:4 48:1993 49:4)',
    'rate: 96048 frames in 2001 ms of host clock = 48000.000 Hz',
    'ring: level 150 now, 146 filtered, 98..190 before packets (target 144 of 512)',
    'underruns 1 overruns 0 primes 2; packet build avg 900 max 1400 cycles',
  ];

  // the UAC2 firmware (doc/usb_audio.md)
  const uac2 = [
    'usb audio (UAC2): streaming 48000 Hz 24 bit (alt 1), source synth',
    'since last U: packets sent 30012 missed 4 (host skipped 3, flushed early 1); built 30012 (47:31 48:29950 49:31)',
    'rate: 1440560 frames in 30012 ms of host clock = 48000.266 Hz',
    'ring: level 104 now, 96 filtered, 65..128 before packets (target 96 = 2000 us, of 512)',
    'faults: underruns 2 overruns 1 primes 2 (silent packets 5), fast starts 1',
    'frames: not ready at SOF 1; SOF late (>1.1 ms) 7 lost 0, max interval 1012 us',
    'builds: after fetch 30012, after miss 0, at SOF 1; fetch at 95..140 us (avg 110) after SOF; build avg 1900 max 2600 cycles',
    'synth: commit 210 us avg, 420 max after its DMA interrupt (block 667 us); off cadence 0; since boot: blocks lost 3, repeated 3',
    'cpu: usb audio ISR hooks 9000000 cycles = 0.22% over 30012 ms; longest lock: thread 12 us, ISR 4 us',
  ];

  test('UAC1 firmware: every number', () {
    final s = parseUsbAudioStats(uac1)!;
    expect([s.streaming, s.uac, s.alt, s.sent, s.missed, s.built, s.size47, s.size48, s.size49], [true, null, 1, 2001, 3, 2001, 4, 1993, 4]);
    expect(s.rateHz, 48000.0);
    expect([s.ringNow, s.ringFiltered, s.ringMin, s.ringMax, s.ringTarget, s.ringSize, s.priming], [150, 146, 98, 190, 144, 512, false]);
    expect([s.underruns, s.overruns, s.primes, s.hostSkipped, s.notReady, s.drops], [1, 0, 2, null, null, 1]);
  });

  test('UAC2 firmware: the new fields; board dropouts = underruns + host skipped + not ready', () {
    final s = parseUsbAudioStats(uac2)!;
    expect([s.uac, s.sent, s.missed, s.hostSkipped, s.flushedEarly, s.built, s.size48], [2, 30012, 4, 3, 1, 30012, 29950]);
    expect(s.rateHz, 48000.266);
    expect([s.ringNow, s.ringFiltered, s.ringMin, s.ringMax, s.ringTarget, s.ringSize], [104, 96, 65, 128, 96, 512]);
    expect([s.underruns, s.overruns, s.primes, s.silentPackets, s.fastStarts], [2, 1, 2, 5, 1]);
    expect([s.notReady, s.sofLate, s.sofLost, s.sofMaxIntervalUs], [1, 7, 0, 1012]);
    expect([s.fetchMinUs, s.fetchMaxUs], [95, 140]);
    expect([s.synthCommitMaxUs, s.offCadence, s.blocksLost], [420, 0, 3]);
    expect(s.cpuPercent, 0.22);
    expect([s.lockThreadUs, s.lockIsrUs], [12, 4]);
    expect(s.drops, 2 + 3 + 1);
    expect(isLastUsbAudioLine(uac2.last), isTrue);
    expect(isLastUsbAudioLine(uac1.last), isTrue);
    expect(isLastUsbAudioLine(uac2[4]), isFalse, reason: 'the faults line is not the end');
  });

  test('tolerant: lines in another order, words added, some missing, other lines around', () {
    final s = parseUsbAudioStats([
      'some unrelated line',
      'faults: underruns 0 overruns 5 primes 0',
      'ring: level 12 now, -3 filtered, -10..40 before packets (target 96 of 256), priming',
      'usb audio (UAC1): idle (alt 0), source test tone (L 1 kHz, R 500 Hz, -6 dBFS)',
    ])!;
    expect(s.streaming, isFalse);
    expect(s.uac, 1);
    expect(s.sent, isNull);
    expect([s.ringFiltered, s.ringMin, s.ringMax, s.ringTarget, s.ringSize, s.priming], [-3, -10, 40, 96, 256, true]);
    expect(s.drops, 0, reason: 'overruns: the host stopped fetching, not a board dropout');
  });

  test('not a StcU reply: null', () {
    expect(parseUsbAudioStats(const []), isNull);
    expect(parseUsbAudioStats(const ['Stcs', 'voice 3 viola']), isNull);
  });

  test('U and Stct: the commands and the reply', () {
    expect(Cmd.usbAudio(), [0x53, 0x74, 0x63, 0x55]);
    expect(Cmd.usbAudioTarget(72), [0x53, 0x74, 0x63, 0x74, 0x30, 0x37, 0x32]);
    expect(Cmd.usbAudioTarget(0), [0x53, 0x74, 0x63, 0x74, 0x30, 0x30, 0x30]);
    expect(() => Cmd.usbAudioTarget(48), throwsRangeError);
    expect(() => Cmd.usbAudioTarget(257), throwsRangeError);
    expect(parseUsbAudioTarget('usb audio target 72 frames (1500 us)'), 72);
    expect(parseUsbAudioTarget('voice 3'), isNull);
  });
}
