// Striso user settings (config) in flash at 0x08020000, as a UF2 file: a port of the config
// functions in tools/striso.py (config_parse, config_uf2, config_update, fmt8 and the update list of
// save_touch), byte-identical (test/config_uf2_test.dart checks against striso.py itself). Records
// are 16 bytes: an 8 character key and an 8 character value, both space padded, between
// "MConfig "/"v1.0    " and "MCfgEnd ".

import 'dart:convert';
import 'dart:typed_data';

import 'voice_keys.dart';

const int configStart = 0x08020000;
const int configEnd = 0x08040000;
const int _magic0 = 0x0A324655, _magic1 = 0x9E5D5157, _magicEnd = 0x0AB16F30, _flagFamily = 0x2000, _family = 0xA21E1295;

class ConfigError implements Exception {
  final String message;
  const ConfigError(this.message);
  @override
  String toString() => message;
}

typedef Record = (String key, String value);

String _ascii(Uint8List b, String what) {
  for (final c in b) {
    if (c > 127) throw ConfigError('$what has a non-ASCII byte (0x${c.toRadixString(16)}): refusing to rewrite this config');
  }
  return String.fromCharCodes(b);
}

bool _eq8(Uint8List b, String s) {
  if (b.length != 8) return false;
  for (var i = 0; i < 8; i++) {
    if (b[i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

/// Records of a config UF2 (e.g. the drive's CONFIG.UF2 readback).
List<Record> configParse(Uint8List uf2) {
  final bd = ByteData.sublistView(uf2);
  final mem = <int, Uint8List>{};
  for (var i = 0; i + 512 <= uf2.length; i += 512) {
    final addr = bd.getUint32(i + 12, Endian.little), size = bd.getUint32(i + 16, Endian.little);
    if (addr >= configStart && addr < configEnd) {
      final end = i + 32 + size < i + 512 ? i + 32 + size : i + 512;
      mem[addr] = Uint8List.sublistView(uf2, i + 32, end);
    }
  }
  final data = BytesBuilder(copy: false);
  for (final a in mem.keys.toList()..sort()) {
    data.add(mem[a]!);
  }
  final d = data.toBytes();
  final recs = <Record>[];
  for (var o = 0; o < d.length - 15; o += 16) {
    final k = Uint8List.sublistView(d, o, o + 8), v = Uint8List.sublistView(d, o + 8, o + 16);
    if (!(k[0] >= 32 && k[0] < 127) || _eq8(k, 'MCfgEnd ')) break;
    if (!_eq8(k, 'MConfig ')) recs.add((_ascii(k, 'a config key'), _ascii(v, 'a config value')));
  }
  return recs;
}

Uint8List _field(String s) {
  if (s.codeUnits.any((c) => c > 127)) throw ConfigError('config field is not ASCII: ${jsonEncode(s)}');
  if (s.length > 8) throw ConfigError('config field too long: ${jsonEncode(s)}');
  return Uint8List.fromList([...s.codeUnits, ...List.filled(8 - s.length, 0x20)]);
}

/// Config UF2 with the header, records and end marker; refuses anything outside the config area.
Uint8List configUf2(List<Record> recs) {
  final b = BytesBuilder()
    ..add(_field('MConfig '))
    ..add(_field('v1.0'));
  for (final (k, v) in recs) {
    b
      ..add(_field(k))
      ..add(_field(v));
  }
  b
    ..add(_field('MCfgEnd '))
    ..add(_field(''));
  var body = b.toBytes();
  final nblocks = (body.length + 255) ~/ 256;
  body = Uint8List.fromList([...body, ...List.filled(nblocks * 256 - body.length, 0xff)]);
  final out = Uint8List(nblocks * 512);
  final bd = ByteData.sublistView(out);
  for (var n = 0; n < nblocks; n++) {
    final addr = configStart + 256 * n;
    if (!(configStart <= addr && addr + 256 <= configEnd)) throw const ConfigError('REFUSED: config would leave the config area');
    final o = n * 512;
    final words = [_magic0, _magic1, _flagFamily, addr, 256, n, nblocks, _family];
    for (var i = 0; i < 8; i++) {
      bd.setUint32(o + 4 * i, words[i], Endian.little);
    }
    out.setRange(o + 32, o + 32 + 256, body, n * 256);
    bd.setUint32(o + 508, _magicEnd, Endian.little);
  }
  return out;
}

/// Merge updates (ordered) into the current records, dropping the keys in [remove].
List<Record> configMerge(List<Record> current, List<Record> updates, [List<String> remove = const []]) {
  final upd = {for (final (k, _) in updates) k}, rem = {...remove};
  return [...current.where((r) => !upd.contains(r.$1) && !rem.contains(r.$1)), ...updates];
}

/// The exact decimal value of a double, as (digits, digits after the point).
(BigInt, int) _exactDecimal(double v) {
  final bits = ByteData(8)..setFloat64(0, v.abs());
  final raw = bits.getUint64(0);
  final expBits = (raw >> 52) & 0x7ff;
  var mant = BigInt.from(raw & 0xfffffffffffff);
  var e = expBits - 1075;
  if (expBits == 0) {
    e = -1074;
  } else {
    mant += BigInt.one << 52;
  }
  if (e >= 0) return (mant << e, 0);
  return (mant * BigInt.from(5).pow(-e), -e);
}

/// Python f"{v:.4f}": correctly rounded, half to even.
String fixed4(double v) {
  if (v.isNaN) return 'nan';
  if (v.isInfinite) return v > 0 ? 'inf' : '-inf';
  final neg = v < 0 || (v == 0 && v.isNegative);
  final (digits, scale) = _exactDecimal(v);
  BigInt keep;
  if (scale <= 4) {
    keep = digits * BigInt.from(10).pow(4 - scale);
  } else {
    final div = BigInt.from(10).pow(scale - 4);
    keep = digits ~/ div;
    final rest = digits - keep * div;
    final twice = rest * BigInt.two;
    if (twice > div || (twice == div && keep.isOdd)) keep += BigInt.one;
  }
  final s = keep.toString().padLeft(5, '0');
  return '${neg ? '-' : ''}${s.substring(0, s.length - 4)}.${s.substring(s.length - 4)}';
}

/// striso.py fmt8: f"{v:.4f}".rstrip("0").rstrip(".") (or "1" for NaN), at most 8 characters.
String fmt8(double v) {
  final s = v.isNaN ? '1' : fixed4(v).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s.length > 8 ? s.substring(0, 8) : s;
}

// ---------------------------------------------------------------------------------------------
// the touch settings and key factors as config updates, exactly like striso.py save_touch()

const _touchKeys = {'pressure': 'presS', 'velocity': 'veloS', 'tilt': 'tiltS', 'bend': 'bendS', 'threshold': 'thres'};
const _touchRange = {'pressure': (0.1, 4.0), 'velocity': (0.1, 4.0), 'tilt': (-4.0, 4.0), 'bend': (0.0, 8.0), 'threshold': (0.0, 0.5)};
final _keyName = RegExp(r'^(C_|Db|C#|D_|Eb|D#|E_|F_|Gb|F#|G_|Ab|G#|A_|Bb|A#|B_)[1-9]$');

/// A named value as the board lists it ('g' touch settings, 'k' key factors).
typedef NamedValue = (String name, double value);

class TouchValues {
  final List<NamedValue> touch, keys;
  const TouchValues(this.touch, this.keys);
}

({List<Record> updates, List<String> remove}) touchUpdates(TouchValues values) {
  final touch = values.touch, keys = values.keys;
  if (touch.length != 5 || keys.length != 61) throw const ConfigError('this firmware has no live touch/key settings');
  final seenT = <String>{};
  for (final (name, value) in touch) {
    final r = _touchRange[name];
    if (r == null || !seenT.add(name)) throw ConfigError('unexpected touch setting ${jsonEncode(name)}');
    if (!(value >= r.$1 - 1e-6 && value <= r.$2 + 1e-6)) throw ConfigError('touch $name out of range: $value');
  }
  final seenK = <String>{};
  for (final (name, value) in keys) {
    if (!_keyName.hasMatch(name) || !seenK.add(name)) throw ConfigError('unexpected key name ${jsonEncode(name)}');
    if (!(value >= 0.1 - 1e-6 && value <= 10 + 1e-6)) throw ConfigError('key $name factor out of range: $value');
  }
  final updates = <Record>[('iGpreset', '1')];
  for (final (name, value) in touch) {
    updates.add(('fP1${_touchKeys[name]}', fmt8(value)));
  }
  final remove = <String>[];
  for (final (name, value) in keys) {
    final key = 'fCfac$name';
    if ((value - 1.0).abs() > 1e-4) {
      updates.add((key, fmt8(value)));
    } else {
      remove.add(key);
    }
  }
  return (updates: updates, remove: remove);
}

class BuiltConfig {
  final Uint8List data;
  final List<Record> recs, updates, current;
  const BuiltConfig(this.data, this.recs, this.updates, this.current);
}

// the voice keys' records: sGv<key><part> (src/synth/voice_keys.hpp), nothing else
final _voiceKeyRecord = RegExp(r'^sGv\d\d[abpq]$');

/// The voice keys' config edits as the board lists them (Stca), as they are: set writes the
/// value, blank a blank one, default drops the record. Only voice-key records are taken.
({List<Record> updates, List<String> remove}) voiceKeyUpdates(List<ConfigEdit> edits) {
  final updates = <Record>[], remove = <String>[];
  for (final e in edits) {
    if (!_voiceKeyRecord.hasMatch(e.key)) throw ConfigError('not a voice key setting: ${jsonEncode(e.key)}');
    final key = e.key.padRight(8); // (a record's key as the page has it)
    switch (e.kind) {
      case 'set':
        updates.add((key, e.value));
      case 'blank':
        updates.add((key, ''));
      case 'default':
        remove.add(key);
      default:
        throw ConfigError('unknown voice key edit ${jsonEncode(e.kind)}');
    }
  }
  return (updates: updates, remove: remove);
}

/// A whole save: the current config UF2, the values and the voice keys' edits give the UF2 to write.
BuiltConfig buildConfig(Uint8List currentUf2, TouchValues values, {List<ConfigEdit> voiceKeys = const []}) {
  final current = configParse(currentUf2);
  final t = touchUpdates(values), k = voiceKeyUpdates(voiceKeys);
  final u = (updates: [...t.updates, ...k.updates], remove: [...t.remove, ...k.remove]);
  final recs = configMerge(current, u.updates, u.remove);
  final data = configUf2(recs);
  // the file must read back as exactly these records, all inside the config area
  String pad(List<Record> l) => l.map((r) => '${r.$1.padRight(8)}${r.$2.padRight(8)}').join('|');
  if (pad(configParse(data)) != pad(recs)) throw const ConfigError('REFUSED: the new config does not read back identically');
  checkUf2Range(data);
  return BuiltConfig(data, recs, u.updates, current);
}

/// Every block of a UF2 we write must be a Striso config block inside the config area.
void checkUf2Range(Uint8List data) {
  if (data.isEmpty || data.length % 512 != 0) throw const ConfigError('REFUSED: not a UF2 file');
  final bd = ByteData.sublistView(data);
  for (var o = 0; o < data.length; o += 512) {
    final m0 = bd.getUint32(o, Endian.little), m1 = bd.getUint32(o + 4, Endian.little), fam = bd.getUint32(o + 28, Endian.little);
    final addr = bd.getUint32(o + 12, Endian.little), size = bd.getUint32(o + 16, Endian.little);
    if (m0 != _magic0 || m1 != _magic1 || fam != _family || bd.getUint32(o + 508, Endian.little) != _magicEnd) {
      throw ConfigError('REFUSED: block ${o ~/ 512} is not a Striso UF2 block');
    }
    if (!(configStart <= addr && addr + size <= configEnd)) {
      throw ConfigError('REFUSED: block ${o ~/ 512} writes 0x${addr.toRadixString(16)}, outside the config area');
    }
  }
}
