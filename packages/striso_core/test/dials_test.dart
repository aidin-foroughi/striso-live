// StcT, the settings dials from the console (doc/dials_console.md): the replies parsed as the
// firmware writes them, and the client against the mock that answers them.
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

void main() {
  test('the list: even steps, fixed values; a cut list is none', () {
    final l = parseDialList([
      'T dial 0 ch 1 16 1',
      'T dial 2 bend values 12 24 48 96',
      'T dial 4 sustain 0.000 1.000 0.001',
      'T dial 6 fine -100.00 100.00 3.125',
      'T end',
    ])!;
    expect(l.map((d) => d.name), ['ch', 'bend', 'sustain', 'fine']);
    expect((l[0].min, l[0].max, l[0].divisions), (1.0, 16.0, 15));
    expect(l[1].values, [12.0, 24.0, 48.0, 96.0]);
    expect(l[1].divisions, 3);
    expect(l[2].divisions, 1000);
    expect(l[3].divisions, 64);
    expect(parseDialList(['T dial 0 ch 1 16 1']), isNull);
  });

  test('the replies and the command', () {
    expect(parseDialReply('T vol 100'), (name: 'vol', value: 100.0, refused: null));
    expect(parseDialReply('T fine -9.38'), (name: 'fine', value: -9.38, refused: null));
    expect(parseDialReply('T err 7'), (name: null, value: null, refused: 7));
    expect(parseDialReply('T end'), isNull);
    final c = dialSetCommand(3, 100);
    expect(c.sublist(0, 5), [0x53, 0x74, 0x63, 0x54, 3]);
    expect(ByteData.sublistView(c, 5).getFloat32(0, Endian.little), 100);
    expect(dialListCommand()[4], 255);
  });

  test('the client on the mock: the list, a dial clamped and answered, StcY after; a refusal', () async {
    final board = MockBoard(autoplay: false, idleFrames: 0);
    final c = StrisoClient(MockTransport(board: board));
    await c.connect();
    final l = (await c.listDials())!;
    expect(l, hasLength(7));
    expect(await c.setDial(3, 100), 100);
    expect((await c.getState())!.volume, 100);
    expect(await c.setDial(2, 30), 24, reason: 'the bend range dial\'s nearest');
    expect(await c.setDial(5, 99), 15);
    expect(await c.setDial(7, 1), isNull, reason: 'no such dial');
    expect(await c.setDial(3, double.nan), isNull);
    await c.disconnect();
    // a firmware without StcT does not answer
    final old = StrisoClient(MockTransport(board: MockBoard(autoplay: false, idleFrames: 0)..answersDials = false));
    await old.connect();
    expect(await old.listDials(), isNull);
    await old.disconnect();
  });
}
