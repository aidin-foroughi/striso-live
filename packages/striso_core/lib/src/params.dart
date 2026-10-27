// Parameter model helpers: undo history, morph interpolation, mutation, user presets (JSON) and the
// C export. Parameters are matched by name, so presets and morph snapshots survive firmware changes
// that reorder or add parameters.

import 'dart:convert';
import 'dart:math' as math;

import 'protocol.dart';

/// Sound targets: 0 voice, 1 master effects.
const List<int> soundTargets = [Target.voice, Target.fx];

// ---------------------------------------------------------------------------------------------
// snapshots: {voice, values: {target: {name: value}}}

class Snapshot {
  final String voice;
  final Map<int, Map<String, double>> values;
  String label;
  Snapshot(this.voice, this.values, [this.label = '']);

  Map<String, Object?> toJson() => {
    'voice': voice,
    'label': label,
    'values': {for (final e in values.entries) '${e.key}': e.value},
  };
  static Snapshot fromJson(Map<String, Object?> j) => Snapshot(j['voice'] as String, {
    for (final e in (j['values'] as Map).entries)
      int.parse(e.key as String): {for (final v in (e.value as Map).entries) v.key as String: (v.value as num).toDouble()},
  }, (j['label'] as String?) ?? '');
}

Snapshot snapshot(Map<int, List<Param>> state, String voiceName) => Snapshot(voiceName, {
  for (final t in soundTargets) t: {for (final p in state[t] ?? const <Param>[]) p.name: p.value},
});

// ---------------------------------------------------------------------------------------------
// morph: corners at (0,0) (1,0) (0,1) (1,1) in pad units (u right, v down)

const List<(double, double)> cornerPos = [(0, 0), (1, 0), (0, 1), (1, 1)];

List<double> cornerWeights(double u, double v, List<bool> filled) {
  final bil = [(1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v];
  final w = [0.0, 0.0, 0.0, 0.0];
  var sum = 0.0;
  for (var k = 0; k < 4; k++) {
    if (!filled[k]) continue;
    // bilinear, plus a little inverse distance so missing corners never leave a hole
    final d2 = math.pow(u - cornerPos[k].$1, 2) + math.pow(v - cornerPos[k].$2, 2);
    w[k] = bil[k] + 1e-3 / (d2 + 1e-4);
    sum += w[k];
  }
  if (sum > 0) {
    for (var k = 0; k < 4; k++) {
      w[k] /= sum;
    }
  }
  return w;
}

/// Interpolated values for one target's parameters, for parameters present in every filled corner.
List<(Param, double)> morphValues(List<Param> params, List<Snapshot?> corners, List<double> weights, int target) {
  final out = <(Param, double)>[];
  for (final p in params) {
    var v = 0.0;
    var ok = true, any = false;
    for (var k = 0; k < 4; k++) {
      final c = corners[k];
      if (c == null || weights[k] == 0) continue;
      final cv = c.values[target]?[p.name];
      if (cv == null) {
        ok = false;
        break;
      }
      v += weights[k] * cv;
      any = true;
    }
    if (ok && any) out.add((p, conformValue(p, p.kind == Kind.onOff ? (v >= 0.5 ? 1 : 0) : v)));
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// mutate: small random moves within the ranges

List<(Param, double)> mutateValues(List<Param> params, double amount, math.Random random, {Set<String> locked = const {}}) {
  double gauss() {
    final u = math.max(1e-9, random.nextDouble()), v = random.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  final out = <(Param, double)>[];
  for (final p in params) {
    if (locked.contains(p.name)) continue;
    final span = p.max - p.min;
    var v = p.value;
    if (p.kind == Kind.continuous) {
      v += gauss() * amount * span * 0.5;
    } else if (p.kind == Kind.integer) {
      if (random.nextDouble() < amount) v += random.nextDouble() < 0.5 ? -1 : 1;
    } else if (random.nextDouble() < amount / 3) {
      v = v >= 0.5 ? 0 : 1;
    }
    v = conformValue(p, v);
    if (v != p.value) out.add((p, v));
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// undo history: entries are lists of changes {target, name, from, to}

class Change {
  final int target;
  final String name;
  final double from;
  double to;
  Change(this.target, this.name, this.from, this.to);
}

class HistoryEntry {
  final String label;
  final List<Change> changes;
  const HistoryEntry(this.label, this.changes);
}

class _Open {
  final String label;
  final String? key;
  final changes = <String, Change>{};
  _Open(this.label, this.key);
}

class History {
  final int limit;
  final _undo = <HistoryEntry>[];
  final _redo = <HistoryEntry>[];
  _Open? _open;
  History([this.limit = 200]);

  /// Start (or continue, for the same key) a transaction.
  void begin(String label, [String? key]) {
    if (_open != null && key != null && _open!.key == key) return;
    commit();
    _open = _Open(label, key);
  }

  void record(int target, String name, double from, double to) {
    if (_open == null) begin('Edit');
    final k = '$target:$name';
    final c = _open!.changes[k];
    if (c != null) {
      c.to = to;
    } else {
      _open!.changes[k] = Change(target, name, from, to);
    }
  }

  void commit() {
    final o = _open;
    _open = null;
    if (o == null) return;
    final changes = o.changes.values.where((c) => c.from != c.to).toList();
    if (changes.isEmpty) return;
    _undo.add(HistoryEntry(o.label, changes));
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// The changes to apply: (target, name, value).
  ({String label, List<(int, String, double)> changes})? undo() {
    commit();
    if (_undo.isEmpty) return null;
    final e = _undo.removeLast();
    _redo.add(e);
    return (label: e.label, changes: [for (final c in e.changes) (c.target, c.name, c.from)]);
  }

  ({String label, List<(int, String, double)> changes})? redo() {
    commit();
    if (_redo.isEmpty) return null;
    final e = _redo.removeLast();
    _undo.add(e);
    return (label: e.label, changes: [for (final c in e.changes) (c.target, c.name, c.to)]);
  }

  void clear() {
    _open = null;
    _undo.clear();
    _redo.clear();
  }

  bool get canUndo => _undo.isNotEmpty || (_open?.changes.isNotEmpty ?? false);
  bool get canRedo => _redo.isNotEmpty;
}

// ---------------------------------------------------------------------------------------------
// user presets

const presetFormat = 'striso-live-preset';
const collectionFormat = 'striso-live-presets';

class PresetParam {
  final int index;
  final String name, group;
  final double value, min, max;
  final int kind;
  const PresetParam(this.index, this.name, this.group, this.value, this.min, this.max, this.kind);
  Map<String, Object?> toJson() => {'index': index, 'name': name, 'group': group, 'value': value, 'min': min, 'max': max, 'kind': kind};
  static PresetParam fromJson(Map j) => PresetParam(
    (j['index'] as num?)?.toInt() ?? 0,
    j['name'] as String,
    (j['group'] as String?) ?? '',
    (j['value'] as num).toDouble(),
    (j['min'] as num?)?.toDouble() ?? 0,
    (j['max'] as num?)?.toDouble() ?? 1,
    (j['kind'] as num?)?.toInt() ?? 0,
  );
}

class Preset {
  final String name, voice, engine, created;
  final List<PresetParam> params, fx;
  const Preset({required this.name, required this.voice, required this.engine, required this.created, required this.params, required this.fx});

  Map<String, Object?> toJson() => {
    'format': presetFormat,
    'version': 1,
    'name': name,
    'voice': voice,
    'engine': engine,
    'created': created,
    'params': [for (final p in params) p.toJson()],
    'fx': [for (final p in fx) p.toJson()],
  };
}

Preset makePreset(String name, String voiceName, Map<int, List<Param>> state, {DateTime? now}) {
  List<PresetParam> strip(List<Param>? l) => [
    for (final p in l ?? const <Param>[]) PresetParam(p.index, p.name, p.group, p.value, p.min, p.max, p.kind),
  ];
  return Preset(
    name: name,
    voice: voiceName,
    engine: voiceName.split(':').first,
    created: (now ?? DateTime.now()).toUtc().toIso8601String(),
    params: strip(state[Target.voice]),
    fx: strip(state[Target.fx]),
  );
}

String? validatePreset(Object? p) {
  if (p is! Map) return 'not an object';
  if (p['name'] is! String || (p['name'] as String).trim().isEmpty) return 'missing name';
  if (p['voice'] is! String || (p['voice'] as String).isEmpty) return 'missing voice';
  for (final key in ['params', 'fx']) {
    final l = p[key];
    if (l is! List) return 'missing $key';
    for (final q in l) {
      if (q is! Map || q['name'] is! String || q['value'] is! num || !(q['value'] as num).isFinite) return 'bad entry in $key';
    }
  }
  return null;
}

/// One preset or a collection; returns the valid presets and the errors.
({List<Preset> presets, List<String> errors}) parsePresetFile(String text) {
  Object? data;
  try {
    data = jsonDecode(text);
  } catch (e) {
    return (presets: <Preset>[], errors: ['not JSON: $e']);
  }
  final list = data is List ? data : (data is Map && data['format'] == collectionFormat ? data['presets'] as List? ?? const [] : [data]);
  final presets = <Preset>[], errors = <String>[];
  for (final p in list) {
    final err = validatePreset(p);
    if (err != null) {
      errors.add('${p is Map ? p['name'] ?? 'preset' : 'preset'}: $err');
      continue;
    }
    final m = p as Map;
    final voice = m['voice'] as String;
    presets.add(
      Preset(
        name: m['name'] as String,
        voice: voice,
        engine: (m['engine'] as String?) ?? voice.split(':').first,
        created: (m['created'] as String?) ?? '',
        params: [for (final q in m['params'] as List) PresetParam.fromJson(q as Map)],
        fx: [for (final q in m['fx'] as List) PresetParam.fromJson(q as Map)],
      ),
    );
  }
  return (presets: presets, errors: errors);
}

String collectionJson(List<Preset> presets) => const JsonEncoder.withIndent('  ').convert({
  'format': collectionFormat,
  'version': 1,
  'exported': DateTime.now().toUtc().toIso8601String(),
  'presets': [for (final p in presets) p.toJson()],
});

// ---------------------------------------------------------------------------------------------
// C export: arrays in EngineParams index order, one value per line with its name

/// The shortest decimal that rounds to the same float32, with a C float suffix.
String cFloat(double x) {
  final v = toFloat32(x);
  if (!v.isFinite) return '0.0f';
  var s = v.toString();
  for (var d = 1; d <= 9; d++) {
    final t = double.parse(v.toStringAsPrecision(d));
    if (toFloat32(t) == v) {
      s = _shortest(t);
      break;
    }
  }
  if (!RegExp('[.eE]').hasMatch(s)) s += '.0';
  return '${s}f';
}

// like JS String(number): 0.1, 46, 1e-7 (Dart's double.toString follows the same algorithm,
// except that it writes integral values as 46.0)
String _shortest(double t) => t == t.truncateToDouble() && t.abs() < 1e21 ? t.toInt().toString() : t.toString();

String cIdent(String name) {
  var id = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (RegExp('^[0-9]').hasMatch(id)) id = 'p_$id';
  return id.isEmpty ? 'preset' : id;
}

String presetToC(Preset preset) {
  final id = cIdent(preset.name);
  final engine = preset.engine;
  final lines = <String>[
    '// Striso Live preset "${preset.name.replaceAll('"', "'")}" for $engine (made from ${preset.voice}), ${preset.created.length >= 10 ? preset.created.substring(0, 10) : ''}'
        .trimRight(),
    '// Values in strisy::EngineParams<$engine::Engine> index order; apply each with',
    '//   *strisy::EngineParams<E>::ptr(e, i) = v; strisy::EngineParams<E>::changed(e, i);',
  ];
  void block(List<PresetParam> list, String arr, String label) {
    final sorted = [...list]..sort((a, b) => a.index - b.index);
    if (sorted.isEmpty) {
      lines.add('// (no $label parameters)');
      return;
    }
    final w = [4, ...sorted.map((p) => cFloat(p.value).length)].reduce(math.max) + 1;
    lines.add('static const float $arr[${sorted.length}] = {');
    String? group;
    for (final p in sorted) {
      if (p.group != group) {
        group = p.group;
        lines.add('\t// $group');
      }
      lines.add('\t${'${cFloat(p.value)},'.padRight(w + 1)}// ${p.index.toString().padLeft(2)} ${p.name}');
    }
    lines.add('};');
  }

  block(preset.params, 'preset_${id}_${cIdent(engine)}', 'voice');
  block(preset.fx, 'preset_${id}_fx', 'effects');
  return '${lines.join('\n')}\n';
}

// ---------------------------------------------------------------------------------------------
// display

String formatValue(double min, double max, int kind, double v) {
  if (kind == Kind.onOff) return v >= 0.5 ? 'on' : 'off';
  if (kind == Kind.integer) return v.round().toString();
  final a = v.abs(), span = (max - min).abs();
  var d = span >= 100
      ? 0
      : span >= 10
      ? 1
      : span >= 1
      ? 2
      : 3;
  if (a >= 1000) d = 0;
  var s = v.toStringAsFixed(d);
  if (RegExp(r'^-0(\.0*)?$').hasMatch(s)) s = s.substring(1);
  return s;
}

String formatParam(Param p, [double? v]) => formatValue(p.min, p.max, p.kind, v ?? p.value);
