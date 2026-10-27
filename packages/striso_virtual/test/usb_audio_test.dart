// striso_core's client asking the virtual board for its USB audio counters (StcU) and setting its
// ring target (Stct): the board answers in the UAC2 firmware's layout. The parser against both
// firmwares' layouts: striso_core's test/usb_audio_stats_test.dart.
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  test('U and t on the virtual board: its counters, and the ring target it reports', skip: libraryMissing, () async {
    final (b, c) = await boot();
    final s = (await c.getUsbAudioStats())!;
    expect(s.uac, 2);
    expect(s.streaming, isFalse, reason: 'no host streams the virtual board\'s USB audio');
    expect(s.drops, 0);
    final target = s.ringTarget!;
    expect(await c.setUsbAudioTarget(0), target, reason: '0 only asks');
    final other = target == 80 ? 96 : 80;
    expect(await c.setUsbAudioTarget(other), other);
    expect((await c.getUsbAudioStats())!.ringTarget, other);
  });
}
