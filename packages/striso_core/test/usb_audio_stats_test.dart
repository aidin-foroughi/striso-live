// StcU: the board's USB audio counters, parsed by their words (the firmware's reply is text).
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

void main() {
  // as usb_audio.c prints it
  const reply = [
    'usb audio: streaming 48000 Hz 24 bit (alt 1), source synth',
    'since last U: packets sent 2001 missed 3 built 2001 (47:4 48:1993 49:4)',
    'rate: 96048 frames in 2001 ms of host clock = 48000.000 Hz',
    'ring: level 150 now, 146 filtered, 98..190 before packets (target 144 of 512)',
    'underruns 1 overruns 0 primes 2; packet build avg 900 max 1400 cycles',
  ];

  test('every number of the firmware reply', () {
    final s = parseUsbAudioStats(reply)!;
    expect([s.streaming, s.alt, s.sent, s.missed, s.built, s.size47, s.size48, s.size49], [true, 1, 2001, 3, 2001, 4, 1993, 4]);
    expect(s.rateHz, 48000.0);
    expect([s.ringNow, s.ringFiltered, s.ringMin, s.ringMax, s.ringTarget, s.ringSize, s.priming], [150, 146, 98, 190, 144, 512, false]);
    expect([s.underruns, s.overruns, s.primes, s.drops], [1, 0, 2, 1]);
  });

  test('tolerant: lines in another order, words added, some missing, other lines around', () {
    final s = parseUsbAudioStats([
      'some unrelated line',
      'underruns 0 overruns 5 primes 0',
      'ring: level 12 now, -3 filtered, -10..40 before packets (target 96 of 256), priming',
      'usb audio: idle (alt 0), source test tone (L 1 kHz, R 500 Hz, -6 dBFS)',
    ])!;
    expect(s.streaming, isFalse);
    expect(s.sent, isNull);
    expect([s.ringFiltered, s.ringMin, s.ringMax, s.ringTarget, s.priming], [-3, -10, 40, 96, true]);
    expect(s.drops, 5);
  });

  test('not a StcU reply: null', () {
    expect(parseUsbAudioStats(const []), isNull);
    expect(parseUsbAudioStats(const ['Stcs', 'voice 3 viola']), isNull);
  });

  test('the client asks with U; the demo board answers like the firmware', () async {
    expect(Cmd.usbAudio(), [0x53, 0x74, 0x63, 0x55]);
    final t = MockTransport();
    final c = StrisoClient(t);
    await c.connect();
    t.board.usbAudioUnderruns = 2;
    final s = await c.getUsbAudioStats();
    expect(s, isNotNull);
    expect(s!.streaming, isTrue);
    expect(s.underruns, 2);
    expect(s.ringTarget, 144);
    final again = await c.getUsbAudioStats();
    expect(again!.underruns, 0, reason: 'counters since the last call');
    await c.disconnect();
  });
}
