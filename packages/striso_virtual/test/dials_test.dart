// striso_core's client against the virtual board's settings dials (StcT, doc/dials_console.md): the
// list, a dial set and answered and in StcY after, a dial of fixed values to its nearest, one
// clamped to its range, and the refusals. The reply formats: striso_core's test/dials_test.dart.
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  test('the dials on the virtual board: the list, set and answered, StcY after; refusals', skip: libraryMissing, () async {
    final (b, c) = await boot();
    final l = (await c.listDials())!;
    expect(l, isNotEmpty);
    expect(l.map((d) => d.id), [for (var i = 0; i < l.length; i++) i]);
    // the volume: its StcY field follows
    final vol = l.firstWhere((d) => d.name == 'vol');
    expect(await c.setDial(vol.id, vol.max), vol.max);
    expect((await c.getState())!.volume, vol.max);
    // a dial of fixed values takes the nearest
    final fixed = l.firstWhere((d) => d.values != null && d.values!.length >= 3);
    final v = fixed.values!;
    final near = v[1] + (v[2] - v[1]) * 0.25;
    expect(await c.setDial(fixed.id, near), v[1], reason: 'the nearest of ${fixed.name}\'s values');
    // a range dial past its end: its max
    final ranged = l.firstWhere((d) => d.values == null && d.id != vol.id);
    expect(await c.setDial(ranged.id, ranged.max + 50), ranged.max);
    // refused: no such dial, no number
    expect(await c.setDial(l.length, 1), isNull, reason: 'no such dial');
    expect(await c.setDial(vol.id, double.nan), isNull);
  });
}
