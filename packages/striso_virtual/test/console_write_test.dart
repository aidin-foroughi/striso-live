// The transport's writes to the virtual board's console (writeAll): a piece the console can't
// hold now (sv_console_write's 0) is written again as the board drains, none dropped or written
// twice; a board gone is false; no progress at all for the stall time is an error. No library
// needed: a fake console.
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

void main() {
  test('refused pieces are written again in order, until all of it is in', () async {
    // a console that holds 3 pieces of 4 bytes; the board reads one piece every other try
    const piece = 4, capacity = 3;
    final taken = <int>[];
    var buffered = 0, tries = 0, refusals = 0;
    final data = List<int>.generate(40, (i) => i);
    int write(int from) {
      var off = from;
      while (off < data.length) {
        if (tries++ % 2 == 0 && buffered > 0) buffered--; // the board read a piece
        if (buffered == capacity) {
          refusals++;
          return off;
        }
        final n = data.length - off < piece ? data.length - off : piece;
        taken.addAll(data.sublist(off, off + n));
        buffered++;
        off += n;
      }
      return off;
    }

    expect(await writeAll(write, data.length, retry: Duration.zero), isTrue);
    expect(taken, data, reason: 'every byte once, in order');
    expect(refusals, greaterThan(0), reason: 'the console was full on the way');
  });

  test('a board gone: false; a console that never takes more: an error after the stall', () async {
    expect(await writeAll((from) => -1, 10), isFalse);
    expect(await writeAll((from) => from == 0 ? 5 : -1, 10), isFalse);
    await expectLater(writeAll((from) => 3, 10, stall: const Duration(milliseconds: 50), retry: const Duration(milliseconds: 5)), throwsStateError);
  });
}
