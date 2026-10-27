// Key equalizer math: median, the factor suggestion, the live pressure trace.

double? median(Iterable<double> xs) {
  final s = xs.toList()..sort();
  if (s.isEmpty) return null;
  final m = s.length >> 1;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

class Measured {
  final int n, id;
  final double peak, factor;
  final String name;
  const Measured({required this.n, this.id = -1, required this.peak, required this.factor, this.name = ''});
}

class FactorChange {
  final Measured key;
  final double to, want;
  final bool clamped;
  const FactorChange(this.key, this.to, this.want, this.clamped);
}

class Suggestion {
  final double? median;
  final List<FactorChange> changes;
  final int used;
  final List<Measured> skipped;
  const Suggestion(this.median, this.changes, this.used, this.skipped);
}

double _round3(double x) => (x * 1000).round() / 1000;

/// Factors that bring every measured key's peak to the median of the measured peaks. Pressure is
/// proportional to the factor (button_read.c: c_force = factory * factor), so the new factor is
/// factor * median / peak, clamped. Only measured keys change; peaks that are tiny or at the top
/// of the range are left out.
Suggestion suggestFactors(
  List<Measured> measured, {
  double lo = 0.6,
  double hi = 1.6,
  int minKeys = 3,
  double minPeak = 0.03,
  double maxPeak = 1.7,
  double minChange = 0.005,
}) {
  final used = measured.where((m) => m.peak >= minPeak && m.peak <= maxPeak).toList();
  final skipped = measured.where((m) => !used.contains(m)).toList();
  if (used.length < minKeys) return Suggestion(null, const [], used.length, skipped);
  final med = median(used.map((m) => m.peak))!;
  final changes = <FactorChange>[];
  for (final m in used) {
    final want = m.factor * med / m.peak;
    final to = _round3(want.clamp(lo, hi));
    if ((to - m.factor).abs() >= minChange) changes.add(FactorChange(m, to, want, to != _round3(want)));
  }
  return Suggestion(med, changes, used.length, skipped);
}

/// The last [window] of a key's pressure: (time ms, value), oldest first.
class PressureTrace {
  final double window;
  final int size;
  late final List<double> _t = List.filled(size, 0), _v = List.filled(size, 0);
  int _n = 0, _head = 0;
  PressureTrace({this.window = 2000, this.size = 512});

  void reset() {
    _n = 0;
    _head = 0;
  }

  void push(double t, double v) {
    _t[_head] = t;
    _v[_head] = v;
    _head = (_head + 1) % size;
    if (_n < size) _n++;
  }

  List<(double, double)> points(double now) {
    final out = <(double, double)>[];
    for (var k = _n; k > 0; k--) {
      final i = (_head - k + size) % size;
      if (now - _t[i] <= window) out.add((_t[i], _v[i]));
    }
    return out;
  }

  double max(double now) => points(now).fold(0.0, (m, p) => p.$2 > m ? p.$2 : m);
}
