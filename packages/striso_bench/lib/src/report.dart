// The bench's JSON report (schema "striso-bench/1"), its checks against sane bounds, and a
// validator the tests and the hardware suite use.
//
// {
//   "schema": "striso-bench/1",
//   "command": "usb-in" | "out" | "through" | "soak" | "stats" | "targets" | "all",
//   "started": ISO 8601, "duration_s": number,
//   "host": {"os": string, "os_version": string, "dart": string, "audio": string, "sim": bool},
//   "board": {"console": string, "version": string|null} | null,
//   "results": {<command>: object, ...},
//   "checks": [{"name": string, "ok": bool, "value": any, "limit": string}],
//   "ok": bool,
//   "notes": [string]
// }

const schemaId = 'striso-bench/1';

class Check {
  final String name, limit;
  final bool ok;
  final Object? value;
  const Check(this.name, this.ok, this.value, this.limit);
  Map<String, Object?> toJson() => {'name': name, 'ok': ok, 'value': value, 'limit': limit};
}

Object? _path(Object? j, String path) {
  Object? v = j;
  for (final k in path.split('.')) {
    if (v is Map && v.containsKey(k)) {
      v = v[k];
    } else if (v is List && int.tryParse(k) != null && int.parse(k) < v.length) {
      v = v[int.parse(k)];
    } else {
      return null;
    }
  }
  return v;
}

/// A value inside a report by its dotted path ("results.usb_in_exclusive.usb_in_ms.median").
Object? at(Object? report, String path) => _path(report, path);

/// The checks the hardware suite asserts (only for what the report has).
List<Check> checksOf(Map<String, Object?> results, {bool sim = false}) {
  final out = <Check>[];
  num? n(String p) => _path(results, p) as num?;
  for (final k in ['usb_in_exclusive', 'usb_in_shared']) {
    final med = n('$k.usb_in_ms.median');
    // exclusive: the device's own short period; shared: Windows' 10 ms engine buffers on top
    final limit = k.endsWith('exclusive') ? 8 : 20;
    if (med != null) out.add(Check('$k: median latency', med < limit, med, '< $limit ms'));
    final found = n('$k.markers.found'), sent = n('$k.markers.sent');
    if (found != null && sent != null) out.add(Check('$k: markers found', sent > 0 && found >= sent * 0.9, '$found of $sent', '>= 90%'));
  }
  for (final k in ['through', 'soak']) {
    final u = n('$k.board_underruns');
    final polls = n('$k.board_polls');
    if (u != null && (polls ?? 0) > 0) out.add(Check('$k: board underruns', u == 0, u, '0'));
    final v = n('$k.silence_violations');
    if (v != null) out.add(Check('$k: output stayed silent', v == 0, v, '0 non-zero samples'));
  }
  final outCfg = _path(results, 'out.configs');
  if (outCfg is List) {
    for (final c in outCfg.whereType<Map>()) {
      final v = c['silence_violations'];
      if (v is num) out.add(Check('out ${c['exclusive'] == true ? 'exclusive' : 'shared'} ${c['period_asked']}: output stayed silent', v == 0, v, '0'));
    }
  }
  final drv = _path(results, 'stats.audio_driver');
  if (_path(results, 'stats') != null && !sim) {
    out.add(Check('stats: audio driver', drv == 'usbaudio2', drv, 'usbaudio2'));
    final midi = _path(results, 'stats.midi_port');
    out.add(Check('stats: MIDI port present', midi != null, midi, 'a MIDI input named Striso'));
    final ep = _path(results, 'stats.audio_input');
    out.add(Check('stats: audio input present', ep != null, ep, 'the Striso input listed'));
  }
  return out;
}

/// Problems with a report's shape (empty: valid).
List<String> validateReport(Object? r) {
  final p = <String>[];
  if (r is! Map) return ['not an object'];
  void need(String k, bool Function(Object?) ok, String what) {
    if (!r.containsKey(k)) {
      p.add('missing "$k"');
    } else if (!ok(r[k])) {
      p.add('"$k" is not $what');
    }
  }

  need('schema', (v) => v == schemaId, schemaId);
  need('command', (v) => v is String && v.isNotEmpty, 'a command');
  need('started', (v) => v is String && DateTime.tryParse(v) != null, 'an ISO time');
  need('duration_s', (v) => v is num && v >= 0, 'a duration');
  need('host', (v) => v is Map && v['os'] is String && v['sim'] is bool, 'a host');
  need('board', (v) => v == null || (v is Map && v['console'] is String), 'null or a board');
  need('results', (v) => v is Map, 'an object');
  need('checks', (v) => v is List && v.every((c) => c is Map && c['name'] is String && c['ok'] is bool && c['limit'] is String), 'a list of checks');
  need('ok', (v) => v is bool, 'a bool');
  need('notes', (v) => v is List && v.every((e) => e is String), 'a list of strings');
  final res = r['results'];
  if (res is Map) {
    for (final e in res.entries) {
      if (e.value is! Map) p.add('results.${e.key} is not an object');
    }
    // every statistic has its numbers
    void stats(Object? v, String where) {
      if (v is Map) {
        if (v.containsKey('median')) {
          for (final k in ['n', 'min', 'median', 'p95', 'max', 'mean']) {
            if (v[k] is! num) p.add('$where.$k is not a number');
          }
          final mn = v['min'], md = v['median'], mx = v['max'];
          if (mn is num && md is num && mx is num && !(mn <= md && md <= mx)) p.add('$where: min <= median <= max fails');
        }
        for (final e in v.entries) {
          stats(e.value, '$where.${e.key}');
        }
      } else if (v is List) {
        for (var i = 0; i < v.length; i++) {
          stats(v[i], '$where.$i');
        }
      }
    }

    stats(res, 'results');
  }
  return p;
}
