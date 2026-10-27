// The key layout (StcG) as the firmware writes it (test/fixtures/key_layout.txt): the parser, the
// layout's own definitions (a key's 12-TET pitch, its spelling) and the picture's geometry. The
// client asking a board: packages/striso_virtual/test/client_test.dart.
import 'dart:math' as math;

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/silent_transport.dart';

final _reply = readFixture('key_layout.txt')['G'];

void main() {
  group('G reply parser', () {
    test('the reply: header, a line per key, end', () {
      expect(_reply.first, matches(RegExp(r'^layout \d+ \d+ \d+ flip=[01]$')));
      expect(_reply.last, 'layout end');
      final l = parseKeyLayout(_reply)!;
      expect(l.keys.length, _reply.length - 2);
      final head = _reply.first.split(' ');
      expect(l.keys.length, int.parse(head[1]));
      expect(l.buttons, int.parse(head[2]));
      expect(l.startNote, int.parse(head[3]));
      expect(l.flip, head[4] == 'flip=1');
      expect(l.lines, _reply);
      for (var n = 0; n < l.keys.length; n++) {
        final k = l.keys[n];
        expect(k.n, n);
        expect(_reply[n + 1], '${k.n} ${k.id} ${k.c0} ${k.c1} ${k.name}');
        expect(l[k.id], same(k));
        expect(l.keyNumberOf(k.id), n);
        expect(k.name.length, 3);
      }
    });

    test('the board as the firmware lays it out: 61 keys on 68 buttons, D4 = 62 at 0 0', () {
      final l = parseKeyLayout(_reply)!;
      expect((l.keys.length, l.buttons, l.startNote, l.flip), (61, 68, 62, false));
      // the buttons no key names are not on the board
      final absent = [for (var id = 0; id < l.buttons; id++) if (l[id] == null) id];
      expect(absent.length, l.buttons - l.keys.length);
      expect(l.keyIds, [for (var id = 0; id < l.buttons; id++) if (l[id] != null) id]);
      expect(l.boardKeys.map((k) => k.id), l.keyIds);
      final d = l.keys.singleWhere((k) => k.c0 == 0 && k.c1 == 0);
      expect(d.name, 'D_3');
      expect(l.noteName(d.id).full, 'D4');
      expect(l.noteName(d.id).midi, 62);
      expect(l.noteName(d.id, 12).full, 'D5');
    });

    test('every key spelled as the firmware names it (its octave one below scientific)', () {
      final l = parseKeyLayout(_reply)!;
      const acc = {'_': '', 'b': '♭', '#': '♯'};
      for (final k in l.keys) {
        final expected = '${k.name[0]}${acc[k.name[1]]}${int.parse(k.name[2]) + 1}';
        expect(l.noteName(k.id).full, expected, reason: 'key ${k.n} ${k.name}');
        expect(k.natural, k.name[1] == '_');
      }
    });

    test('a key\'s 12-TET pitch is 12 c0 + 7 c1 above the start note; the spelling follows c1', () {
      final l = parseKeyLayout(_reply)!;
      for (final k in l.keys) {
        expect(l.pitchOf(k.id), 12 * k.c0 + 7 * k.c1);
        expect(l.noteName(k.id).midi, l.startNote + 12 * k.c0 + 7 * k.c1);
        expect(l.keyTpc(k.id), k.c1 + 2); // C = 0 on the line of fifths, D = 2
        expect(l.noteName(k.id, 0, 5).letter, spell(k.c1 + 5).letter);
      }
      // no two keys play the same 12-TET pitch with the same spelling
      expect({for (final k in l.keys) l.noteName(k.id).full}.length, l.keys.length);
    });

    test('the picture: keys symmetric about 0 0 in height, 17 to 19 mm apart', () {
      final l = parseKeyLayout(_reply)!;
      final ys = l.boardKeys.map((k) => k.y);
      expect((ys.reduce(math.max) + ys.reduce(math.min)).abs(), lessThan(1e-9));
      var minD = double.infinity;
      for (final a in l.boardKeys) {
        for (final b in l.boardKeys) {
          if (!identical(a, b)) minD = math.min(minD, math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)));
        }
      }
      expect(minD, inExclusiveRange(17, 19));
      for (final k in l.boardKeys) {
        expect(k.x, k.c1 * mmPerColumn);
        expect(k.y, k.pitch * mmPerSemitone);
        expect(k.x - keyRadius, greaterThan(plate.x0));
        expect(k.x + keyRadius, lessThan(plate.x1));
      }
    });

    test('its own lines parse again to the same layout (the app keeps them for the next start)', () {
      final l = parseKeyLayout(_reply)!;
      final again = parseKeyLayout(l.lines)!;
      expect(again.lines, l.lines);
      expect([for (final k in again.keys) '${k.n} ${k.id} ${k.c0} ${k.c1} ${k.name}'], [for (final k in l.keys) '${k.n} ${k.id} ${k.c0} ${k.c1} ${k.name}']);
      // CRLF and noise before the header are dropped
      expect(parseKeyLayout(['Stcs', ...[for (final s in _reply) '$s\r']])!.lines, l.lines);
    });

    test('anything less than the whole reply is no layout', () {
      final keys = _reply.sublist(1, _reply.length - 1);
      expect(parseKeyLayout([]), isNull);
      expect(parseKeyLayout(['Stcs', 'hello']), isNull);
      expect(parseKeyLayout(_reply.sublist(0, _reply.length - 1)), isNull, reason: 'no end');
      expect(parseKeyLayout([_reply.first, ...keys.skip(1), 'layout end']), isNull, reason: 'a key missing');
      expect(parseKeyLayout([_reply.first, ...keys, keys.first, 'layout end']), isNull, reason: 'a key twice');
      final f = keys.first.split(' ');
      expect(parseKeyLayout([_reply.first, '${f[0]} 99 ${f[2]} ${f[3]} ${f[4]}', ...keys.skip(1), 'layout end']), isNull, reason: 'a button beyond the count');
      final other = keys[1].split(' ');
      expect(parseKeyLayout([_reply.first, '${f[0]} ${other[1]} ${f[2]} ${f[3]} ${f[4]}', ...keys.skip(1), 'layout end']), isNull, reason: 'a button twice');
      expect(parseKeyLayout([_reply.first, ...keys.take(3), 'garbage', ...keys.skip(3), 'layout end']), isNull, reason: 'a line that is not a key');
    });

    test('a board without G: the request times out, no layout', () async {
      final silent = StrisoClient(SilentTransport());
      await silent.connect();
      final sw = Stopwatch()..start();
      expect(await silent.getKeyLayout(), isNull);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      await silent.disconnect();
    });
  });
}
