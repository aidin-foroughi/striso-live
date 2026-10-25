// Port of tools/app/test/protocol.test.mjs.
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

/// The deterministic random source of the JS tests (an LCG on 32 bits).
double Function() rng(int seed) {
  var s = seed & 0xffffffff;
  return () {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return s / 4294967296;
  };
}

List<int> ascii(String s) => s.codeUnits;

class Collected {
  final messages = <List<int>>[];
  final lines = <String>[];
  late final StreamParser p = StreamParser(onMessage: (src, id, v, n) => messages.add([src, id, ...v.sublist(0, n)]), onLine: lines.add);
}

void main() {
  test('hex float parsing matches the firmware %08lx of the float bits', () {
    expect(hexToFloat('3f800000'), 1);
    expect(hexToFloat('bf800000'), -1);
    expect(hexToFloat('00000000'), 0);
    expect(hexToFloat('40a00000'), 5);
    expect(hexToFloat('3c23d70a'), toFloat32(0.01));
    expect(hexToFloat('3F800000'), 1, reason: 'upper case');
    final nz = hexToFloat('80000000');
    expect(nz == 0 && nz.isNegative, isTrue);
    expect(hexToFloat('7fc00000').isNaN, isTrue);
    expect(hexToFloat('7f800000'), double.infinity);
    expect(() => hexToFloat('3f80000'), throwsFormatException);
    expect(() => hexToFloat('3f80000g'), throwsFormatException);
    final r = rng(7);
    for (var k = 0; k < 1000; k++) {
      final a = r() - 0.5, e = (r() * 12 - 6).floor();
      final x = toFloat32(a * _pow10(e));
      expect(hexToFloat(floatToHex(x)), x);
    }
    expect(floatToHex(0.2), '3e4ccccd');
    expect(floatToHex(-24), 'c1c00000');
  });

  test('14 bit values round trip like main.c pack()', () {
    for (var v = -8192; v <= 8191; v++) {
      final e = encode14(v);
      expect(e[0] < 0x80 && e[1] < 0x80, isTrue);
      expect(decode14(e[0], e[1]), v);
    }
    expect(decode14(0x7f, 0x7f), -1);
    expect(decode14(0x3f, 0x7f), 8191);
    expect(decode14(0x40, 0x00), -8192);
  });

  test('message header layout: 0x80 | src<<3 | count, then id', () {
    final m = encodeMessage(Src.dis, 25, [8191, -100, 0, 4000]);
    expect(m.length, 10);
    expect(m[0], 0x84);
    expect(m[1], 25);
    final a = encodeMessage(Src.accel, 8, [1, 2, 3, 4, 5, 6, 7]);
    expect(a[0], 0x80 | (3 << 3) | 7);
    expect(encodeMessage(Src.control, 1, [1]), [0x91, 1, 0, 1]);
  });

  test('stream framing with text interleaved at random points and random chunking', () {
    final r = rng(42);
    const lines = [
      'voice 3 va:pad',
      '* 12 modal:wine glass',
      'params 0 va:pad 2',
      '0 gain level 3f000000 40a00000 40133333 0',
      'synth blocks 1526 avg 40210 peak 61002 budget 314572 cycles',
      'Q err 0 99',
      '',
    ];
    for (var round = 0; round < 50; round++) {
      final expectedMsgs = <List<int>>[], expectedLines = <String>[];
      final bytes = <int>[];
      var pending = <int>[];
      for (var k = 0; k < 60; k++) {
        if (r() < 0.3) {
          final l = lines[(r() * lines.length).floor()];
          expectedLines.add(l);
          pending.addAll(ascii('$l\r\n'));
        }
        final n = (r() * (pending.length + 1)).floor();
        bytes.addAll(pending.sublist(0, n));
        pending = pending.sublist(n);
        final src = [Src.dis, Src.control, Src.accel, Src.sys][(r() * 4).floor()];
        final count = src == Src.dis ? 4 : (src == Src.accel ? 7 : 1);
        final vals = [for (var j = 0; j < count; j++) (r() * 16384).floor() - 8192];
        final id = (r() * 128).floor();
        expectedMsgs.add([src, id, ...vals]);
        bytes.addAll(encodeMessage(src, id, vals));
      }
      bytes.addAll(pending);
      final c = Collected();
      for (var k = 0; k < bytes.length;) {
        final n = 1 + (r() * 64).floor();
        c.p.push(Uint8List.fromList(bytes.sublist(k, k + n > bytes.length ? bytes.length : k + n)));
        k += n;
      }
      expect(c.messages, expectedMsgs);
      expect(c.lines, expectedLines);
      expect(c.p.stats.truncated, 0);
    }
  });

  test('a truncated message resyncs at the next header', () {
    final c = Collected();
    final a = encodeMessage(Src.dis, 5, [100, 200, 300, 400]);
    final b = encodeMessage(Src.dis, 6, [1, 2, 3, 4]);
    c.p.push(a.sublist(0, 5));
    c.p.push(b);
    c.p.push(ascii('ok\r\n'));
    expect(c.messages, [
      [0, 6, 1, 2, 3, 4],
    ]);
    expect(c.lines, ['ok']);
    expect(c.p.stats.truncated, 1);
  });

  test('a message with no values and CRLF split across chunks', () {
    final c = Collected();
    c.p.push([0x80 | (4 << 3), 9]);
    c.p.push(ascii('Stc'));
    c.p.push([0x73, 0x0d]);
    c.p.push([0x0a]);
    expect(c.messages, [
      [4, 9],
    ]);
    expect(c.lines, ['Stcs']);
  });

  test('commands', () {
    expect(commandChar('V'), [0x53, 0x74, 0x63, 0x56]);
    expect(selectVoiceCommand(3), [0x53, 0x74, 0x63, 0x57, 3, 0]);
    expect(selectVoiceCommand(130), [0x53, 0x74, 0x63, 0x57, 130, 0], reason: 'past 0x80 + n');
    expect(selectVoiceCommand(0x1234), [0x53, 0x74, 0x63, 0x57, 0x34, 0x12], reason: 'little endian');
    expect(() => selectVoiceCommand(-1), throwsRangeError);
    expect(() => selectVoiceCommand(0x10000), throwsRangeError);
    final q = setParamCommand(1, 7, 1.5);
    expect(q.length, setParamLength);
    expect(q, [0x53, 0x74, 0x63, 0x51, 1, 7, 0x00, 0x00, 0xc0, 0x3f]);
    final many = packSetParams([for (var i = 0; i < 13; i++) ParamWrite(0, i, i.toDouble())]);
    expect(many.map((b) => b.length), [60, 60, 10]);
    expect(many.every((b) => b.length <= 64), isTrue);
    expect(many[1][5], 6);
    expect(Cmd.params(2), ascii('Stcg'));
    expect(Cmd.params(3), ascii('Stck'));
  });

  test('reply parsers', () {
    final v = parseVoiceLine('* 12 modal:wine glass')!;
    expect([v.index, v.name, v.current, v.engine, v.preset], [12, 'modal:wine glass', true, 'modal', 'wine glass']);
    final s = parseVoiceLine('  0 strisy')!;
    expect([s.index, s.name, s.current, s.engine, s.preset], [0, 'strisy', false, 'strisy', null]);
    expect(parseVoiceLine('3 gain level 3f000000 40a00000 40133333 0'), isNull);
    expect(parseVoiceSelect('voice 4 va:lead'), (ok: true, index: 4, name: 'va:lead'));
    expect(parseVoiceSelect('no voice 40'), (ok: false, index: 40, name: null));
    final l = parseLoad('synth blocks 1526 avg 31457 peak 62914 budget 314572 cycles')!;
    expect(l.blocks, 1526);
    expect(l.avgPct, closeTo(10, 0.01));
    expect(l.peakPct, closeTo(20, 0.01));
    expect(parseParamsHeader('params 0 modal:wine glass 20'), (target: 0, name: 'modal:wine glass', count: 20));
    expect(parseParamsHeader('params 1 fx 0'), (target: 1, name: 'fx', count: 0));
    final p = parseParamLine('17 cut_env filter 00000000 42a00000 42380000 0')!;
    expect([p.index, p.name, p.group, p.min, p.max, p.value, p.kind], [17, 'cut_env', 'filter', 0, 80, 46, 0]);
    expect(parseParamLine('17 cut_env filter 00000000 42a00000 4238000 0'), isNull);
    expect(parseQErr('Q err 0 99'), (target: 0, index: 99));
    expect(parseVersion('striso_control_strisoboard_v2.2.4 0043002B STRISO').fw, 'strisoboard_v2.2.4');
  });

  test('values conform like apply_params(): clamp, then round integer and on/off kinds', () {
    Param mk(double min, double max, int kind, [double value = 0]) =>
        Param(index: 0, name: 'x', group: 'g', min: min, max: max, value: value, kind: kind);
    final c = mk(0, 7, 1, 3);
    expect(conformValue(c, 2.5), 3);
    expect(conformValue(c, 9), 7);
    expect(conformValue(mk(-1, 1, 0), 0.3), toFloat32(0.3));
    expect(conformValue(mk(-4, 4, 1), -2.5), -3);
    expect(conformValue(mk(0, 1, 2, 1), double.nan), 1);
  });
}

double _pow10(int e) {
  var r = 1.0;
  for (var i = 0; i < e.abs(); i++) {
    r *= 10;
  }
  return e < 0 ? 1 / r : r;
}
