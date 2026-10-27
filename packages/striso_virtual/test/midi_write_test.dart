// MIDI to the virtual board (VirtualBoard.midiWriteAll: writePieces through sv_midi_write, then
// writeAll): sv_midi_write takes a piece whole or says 0 (the host's buffer full, firmware cb3ff57);
// a refused piece is written again as the board reads, every packet once and in order, whole
// packets only; a board gone is false; no progress for the stall time is an error. No library
// needed: a fake sv_midi_write.
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

void main() {
  // a host buffer of [capacity] bytes that the board empties by [drain] bytes every other try
  ({int Function(int off, int n) write, List<int> taken, List<int> pieces, int Function() refusals}) fake(
    List<int> data, {
    int capacity = 24,
    int drain = 8,
  }) {
    final taken = <int>[], pieces = <int>[];
    var held = 0, tries = 0, refused = 0;
    int write(int off, int n) {
      if (tries++ % 2 == 0) held = held > drain ? held - drain : 0; // (the board read some)
      if (held + n > capacity) {
        refused++;
        return 0; // (none taken)
      }
      taken.addAll(data.sublist(off, off + n));
      pieces.add(n);
      held += n;
      return n;
    }

    return (write: write, taken: taken, pieces: pieces, refusals: () => refused);
  }

  test('refused pieces are written again as the board reads: every packet once, in order, whole', () async {
    final data = List<int>.generate(4 * 50, (i) => i & 0xff); // (50 packets)
    final f = fake(data);
    final ok = await writeAll((from) => writePieces(data, from, f.write, piece: 16), data.length, retry: Duration.zero);
    expect(ok, isTrue);
    expect(f.taken, data, reason: 'every byte once, in order');
    expect(f.pieces.every((n) => n % 4 == 0), isTrue, reason: 'whole USB-MIDI packets');
    expect(f.refusals(), greaterThan(0), reason: 'the host buffer was full on the way');
  });

  test('taken at once, or how far it got: the piece refused is not counted (it was dropped as taken)', () {
    final data = List<int>.filled(64, 0);
    expect(writePieces(data, 0, (off, n) => n, piece: 16), 64);
    expect(writePieces(data, 0, (off, n) => off >= 32 ? 0 : n, piece: 16), 32);
    expect(writePieces(data, 32, (off, n) => n, piece: 16), 64);
    expect(writePieces(data, 0, (off, n) => -1, piece: 16), -1);
  });

  test('a board gone: false; a board that never reads: an error after the stall, nothing claimed', () async {
    final data = List<int>.filled(40, 0);
    expect(await writeAll((from) => writePieces(data, from, (off, n) => -1), data.length), isFalse);
    var refused = 0;
    await expectLater(
      writeAll(
        (from) => writePieces(data, from, (off, n) => off >= 16 ? (refused++ * 0) : n, piece: 8),
        data.length,
        stall: const Duration(milliseconds: 50),
        retry: const Duration(milliseconds: 5),
      ),
      throwsStateError,
    );
    expect(refused, greaterThan(1), reason: 'it kept trying');
  });
}
