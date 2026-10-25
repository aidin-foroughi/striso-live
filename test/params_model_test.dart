// ParamsModel without Flutter: edits with undo and redo, A/B against the preset, and the read-back
// that makes the board's values the app's (the preset values stay), on the Dart mock board.
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/params_model.dart';

class Host implements ParamsHost {
  @override
  StrisoClient? client;
  final toasts = <String>[];
  int values = 0, states = 0, edits = 0;
  @override
  void toast(String text, [String kind = '']) => toasts.add(text);
  @override
  void valuesChanged() => values++;
  @override
  void stateChanged() => states++;
  @override
  void editedByUser() => edits++;
}

void main() {
  test('edits, undo and redo, A/B, the board read back', () async {
    final board = MockBoard(autoplay: false, idleFrames: 0);
    final c = StrisoClient(MockTransport(board: board));
    await c.connect();
    final host = Host()..client = c;
    var now = 0.0;
    final m = ParamsModel(host, clock: () => now);
    final r = (await c.getParams(0))!;
    m.load(0, ParamSet(r.name, [for (final p in r.params) p..loadValue = p.value]));
    final p = m.params[0]!.params.firstWhere((q) => q.kind == Kind.continuous);
    final was = p.value, to = conformValue(p, p.min + 0.7 * (p.max - p.min));
    expect(m.isPending(0, p), isFalse);
    m.onEdit(0, p, to, 'begin', 'Edit');
    m.onEdit(0, p, to, 'end');
    expect(m.isPending(0, p), isTrue, reason: 'sent, not confirmed by the board yet');
    expect(m.pendingTargets, [0]);
    expect(m.edited, isTrue);
    expect(m.history.canUndo, isTrue);
    expect(host.edits, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 60)); // the write goes out
    m.setAB(true);
    expect(p.value, was, reason: 'A: the preset');
    m.setAB(false);
    expect(p.value, to, reason: 'B: the edit');
    m.undo();
    expect(p.value, was);
    m.redo();
    expect(p.value, to);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // the board's word: a value changed on the board replaces the app's; the preset value stays
    await m.readBack([0]);
    expect(m.isPending(0, p), isFalse, reason: 'the board read it back');
    expect(p.value, to);
    board.setParam(0, p.index, p.min);
    await m.readBack([0]);
    expect(p.value, conformValue(p, p.min));
    expect(p.loadValue, was);
    await c.disconnect();
  });
}
