// Playing the virtual board by hand (the board view in Demo, tests): keys held with a pressure
// and a tilt, sent as the key scanner sends them while a key is down (a message about every
// millisecond per key, here every [period]), released with a lift velocity.

import 'dart:async';

import 'package:striso_core/striso_core.dart';

import 'board.dart';

class _Held {
  double pres, x, y, vpres;
  _Held(this.pres, this.x, this.y, this.vpres);
}

class VirtualPlayer implements PlayableBoard {
  final VirtualBoard board;
  final Duration period;
  final _held = <int, _Held>{};
  Timer? _timer;

  VirtualPlayer(this.board, {this.period = const Duration(milliseconds: 4)});

  static int _v(double x) => (x * fullScale).round();

  void _send(int id, _Held k) {
    if (board.disposed || !board.attached) return;
    board.injectKey(id, pres: _v(k.pres), velo: _v(k.vpres), x: _v(k.x), y: _v(k.y));
  }

  /// Key [id] (0..67) down or still down: pressure 0..1, tilt -1..1, a strike velocity 0..1.
  @override
  void press(int id, {double pres = 0.5, double x = 0, double y = 0, double strike = 0}) {
    final k = _held[id];
    final vpres = k == null ? (strike > pres ? strike : pres) : (pres - k.pres) * 3;
    final h = _held[id] = _Held(pres < 0.001 ? 0.001 : pres, x, y, vpres);
    _send(id, h);
    _timer ??= Timer.periodic(period, (_) {
      for (final e in _held.entries) {
        e.value.vpres = 0;
        _send(e.key, e.value);
      }
    });
  }

  @override
  void release(int id, [double lift = 0.3]) {
    if (_held.remove(id) == null) return;
    if (!board.disposed && board.attached) board.injectKey(id, pres: 0, velo: _v(-lift));
    if (_held.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// An aux control: Idc.portamento, octave up/down, Idc.alt (settings), the pedals.
  @override
  void control(int id, bool down) {
    if (!board.disposed && board.attached) board.injectControl(id, down ? 1 : 0);
  }

  void releaseAll() {
    for (final id in _held.keys.toList()) {
      release(id, 0);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _held.clear();
  }
}
