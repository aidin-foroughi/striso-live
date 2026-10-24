// Summary statistics for the report: min, median, p95, max, mean (nearest-rank percentiles on the
// sorted values; the median of an even count is the mean of the middle two).

import 'dart:math' as math;

class Stats {
  final int n;
  final double min, median, p95, max, mean;
  const Stats(this.n, this.min, this.median, this.p95, this.max, this.mean);

  static Stats? of(Iterable<num> values) {
    final v = values.map((e) => e.toDouble()).where((e) => e.isFinite).toList()..sort();
    if (v.isEmpty) return null;
    final n = v.length;
    final med = n.isOdd ? v[n ~/ 2] : (v[n ~/ 2 - 1] + v[n ~/ 2]) / 2;
    return Stats(n, v.first, med, percentile(v, 95), v.last, v.reduce((a, b) => a + b) / n);
  }

  /// Nearest rank on sorted values.
  static double percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return double.nan;
    final rank = (p / 100 * sorted.length).ceil();
    return sorted[math.max(0, math.min(sorted.length - 1, rank - 1))];
  }

  static double _r(double x) => (x * 1000).roundToDouble() / 1000;

  Map<String, Object> toJson() => {'n': n, 'min': _r(min), 'median': _r(median), 'p95': _r(p95), 'max': _r(max), 'mean': _r(mean)};

  @override
  String toString() =>
      'min ${min.toStringAsFixed(2)} / median ${median.toStringAsFixed(2)} / p95 ${p95.toStringAsFixed(2)} / max ${max.toStringAsFixed(2)} (n $n)';
}

/// The median of [v] (NaN when empty).
double median(Iterable<num> v) => Stats.of(v)?.median ?? double.nan;
