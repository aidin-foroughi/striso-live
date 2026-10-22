// Striso USB bulk protocol: command encoding, binary stream framing and text reply parsing.
// Port of tools/app/js/protocol.js. Firmware references (striso-control-firmware):
//   pconnection.c  PExReceiveByte: "Stc" + command byte; 'Q' takes 6 more bytes
//   main.c         ThreadSend: header 0x80 | src<<3 | (size-2), id, pack() of the 14 bit values
//   striso.h       source and control ids

import 'dart:typed_data';

class Usb {
  static const vendorId = 0xF055;
  static const productId = 0x57C0;
  static const iface = 2;
  static const epOut = 0x02;
  static const epIn = 0x82;
  static const packet = 64;
}

class Src {
  static const dis = 0, bas = 1, control = 2, accel = 3, sys = 4, midi = 5;
}

class Idc {
  static const portamento = 0, octUp = 1, octDown = 2, alt = 3;
  static const pedalExp = 11, pedal1 = 12, pedal2 = 13, pedal3 = 14;
}

class SysId {
  static const overflowBb = 1, overflowSynth = 2, tooShort = 3, tooLong = 4, battery = 5, temperature = 6;
}

/// Parameter kinds of the firmware's ParamDesc.
class Kind {
  static const continuous = 0, integer = 1, onOff = 2;
}

/// Parameter targets: 0 voice, 1 effects, 2 touch, 3 keys.
class Target {
  static const voice = 0, fx = 1, touch = 2, keys = 3;
}

/// Key values are 14 bit signed, full scale 8191.
const int fullScale = 0x1fff;

/// Motion: acceleration 1024 per g (LSM6DSL path in motionsensor.c), gyro 8192 = 500 dps.
const int accPerG = 1024;
const int gyroFull = 8192;

// ---------------------------------------------------------------------------------------------
// commands

Uint8List command(int byte) {
  if (byte < 0 || byte > 255) throw RangeError('bad command byte $byte');
  return Uint8List.fromList([0x53, 0x74, 0x63, byte]);
}

Uint8List commandChar(String c) => command(c.codeUnitAt(0));

class Cmd {
  static Uint8List version() => commandChar('V');
  static Uint8List load() => commandChar('L');
  static Uint8List voices() => commandChar('v');
  static Uint8List params(int target) => commandChar('pfgk'[target]);
  static Uint8List streamOn() => commandChar('S');
  static Uint8List streamOff() => commandChar('s');
  static Uint8List bootloader() => commandChar('B');
}

Uint8List selectVoiceCommand(int n) {
  if (n < 0 || n > 127) throw RangeError('bad voice index $n');
  return command(0x80 + n);
}

/// "StcQ" + target + index + float32 little endian: 10 bytes, always in one transfer.
const int setParamLength = 10;

void writeSetParam(ByteData out, int at, int target, int index, double value) {
  out.setUint8(at, 0x53);
  out.setUint8(at + 1, 0x74);
  out.setUint8(at + 2, 0x63);
  out.setUint8(at + 3, 0x51);
  out.setUint8(at + 4, target & 0xff);
  out.setUint8(at + 5, index & 0xff);
  out.setFloat32(at + 6, value, Endian.little);
}

Uint8List setParamCommand(int target, int index, double value) {
  final b = Uint8List(setParamLength);
  writeSetParam(ByteData.sublistView(b), 0, target, index, value);
  return b;
}

class ParamWrite {
  final int target, index;
  final double value;
  const ParamWrite(this.target, this.index, this.value);
}

/// Several set-parameter commands, none crossing a 64 byte packet: 6 per transfer.
const int setsPerTransfer = Usb.packet ~/ setParamLength;

List<Uint8List> packSetParams(List<ParamWrite> list) {
  final out = <Uint8List>[];
  for (var k = 0; k < list.length; k += setsPerTransfer) {
    final chunk = list.sublist(k, k + setsPerTransfer > list.length ? list.length : k + setsPerTransfer);
    final buf = Uint8List(chunk.length * setParamLength);
    final bd = ByteData.sublistView(buf);
    for (var j = 0; j < chunk.length; j++) {
      writeSetParam(bd, j * setParamLength, chunk[j].target, chunk[j].index, chunk[j].value);
    }
    out.add(buf);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// float32 <-> 8 hex digits of its bits (the firmware prints %08lx of the bits)

final _f32 = ByteData(4);
final _hex8 = RegExp(r'^[0-9a-fA-F]{8}$');

double hexToFloat(String hex) {
  if (!_hex8.hasMatch(hex)) throw FormatException("bad float hex '$hex'");
  _f32.setUint32(0, int.parse(hex, radix: 16));
  return _f32.getFloat32(0);
}

String floatToHex(double x) {
  _f32.setFloat32(0, x);
  return _f32.getUint32(0).toRadixString(16).padLeft(8, '0');
}

double toFloat32(double x) {
  _f32.setFloat32(0, x);
  return _f32.getFloat32(0);
}

// ---------------------------------------------------------------------------------------------
// 14 bit values, as main.c pack(): out[0] = 0x7f & (in >> 7), out[1] = 0x7f & in

int decode14(int hi, int lo) {
  final v = ((hi & 0x7f) << 7) | (lo & 0x7f);
  return (v & 0x2000) != 0 ? v - 0x4000 : v;
}

List<int> encode14(int v) => [(v >> 7) & 0x7f, v & 0x7f];

/// A whole stream message as the firmware sends it (the mock and the tests use it).
Uint8List encodeMessage(int src, int id, List<num> values) {
  if (values.length > 7) throw RangeError('at most 7 values');
  final out = Uint8List(2 + 2 * values.length);
  out[0] = 0x80 | ((src & 0x0f) << 3) | values.length;
  out[1] = id & 0x7f;
  for (var k = 0; k < values.length; k++) {
    final e = encode14(values[k].round());
    out[2 + 2 * k] = e[0];
    out[3 + 2 * k] = e[1];
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Stream parser. Binary messages start with a byte >= 0x80 and have a known length; payload bytes
// are < 0x80. Any byte outside a message is text; lines end in "\r\n". The firmware writes a
// binary message in one go from a higher priority thread, so a message can split a text line but
// text never splits a message. A byte >= 0x80 inside a message aborts it and starts the next.

typedef MessageHandler = void Function(int src, int id, Int32List values, int count);
typedef LineHandler = void Function(String line);

class ParserStats {
  int messages = 0, lines = 0, truncated = 0, textBytes = 0;
}

class StreamParser {
  MessageHandler onMessage;
  LineHandler onLine;
  final stats = ParserStats();
  int _need = 0, _src = 0, _count = 0, _pos = 0;
  final _raw = Uint8List(15);
  final _values = Int32List(7);
  final _text = <int>[];

  StreamParser({MessageHandler? onMessage, LineHandler? onLine})
      : onMessage = onMessage ?? ((_, _, _, _) {}),
        onLine = onLine ?? ((_) {});

  void reset() {
    _need = 0;
    _text.clear();
  }

  void push(List<int> bytes) {
    for (final b in bytes) {
      if (b & 0x80 != 0) {
        if (_need > 0) stats.truncated++;
        _src = (b >> 3) & 0x0f;
        _count = b & 0x07;
        _need = 1 + 2 * _count;
        _pos = 0;
        continue;
      }
      if (_need > 0) {
        _raw[_pos++] = b;
        if (--_need == 0) _emit();
        continue;
      }
      stats.textBytes++;
      if (b == 0x0a) {
        final line = String.fromCharCodes(_text);
        _text.clear();
        stats.lines++;
        onLine(line);
      } else if (b != 0x0d) {
        if (_text.length < 2048) _text.add(b);
      }
    }
  }

  void _emit() {
    for (var c = 0; c < _count; c++) {
      _values[c] = decode14(_raw[1 + 2 * c], _raw[2 + 2 * c]);
    }
    stats.messages++;
    onMessage(_src, _raw[0], _values, _count);
  }
}

// ---------------------------------------------------------------------------------------------
// text replies

class VoiceEntry {
  final int index;
  final String name, engine;
  final String? preset;
  final bool current;
  const VoiceEntry({required this.index, required this.name, required this.engine, this.preset, this.current = false});
  @override
  String toString() => '${current ? '*' : ' '} $index $name';
}

({String engine, String? preset}) splitVoiceName(String name) {
  final k = name.indexOf(':');
  return k < 0 ? (engine: name, preset: null) : (engine: name.substring(0, k), preset: name.substring(k + 1));
}

final _voiceLine = RegExp(r'^([ *]) (\d+) (.+?)\s*$');

/// `"<'*' or ' '> <n> <name>"  (name may contain spaces and "engine:preset")`
VoiceEntry? parseVoiceLine(String line) {
  final m = _voiceLine.firstMatch(line);
  if (m == null) return null;
  final name = m[3]!;
  final s = splitVoiceName(name);
  return VoiceEntry(index: int.parse(m[2]!), name: name, engine: s.engine, preset: s.preset, current: m[1] == '*');
}

/// Reply to 0x80+n: "voice n name" or "no voice n".
({bool ok, int index, String? name})? parseVoiceSelect(String line) {
  var m = RegExp(r'^voice (\d+) (.+?)\s*$').firstMatch(line);
  if (m != null) return (ok: true, index: int.parse(m[1]!), name: m[2]);
  m = RegExp(r'^no voice (\d+)').firstMatch(line);
  if (m != null) return (ok: false, index: int.parse(m[1]!), name: null);
  return null;
}

class LoadReading {
  final int blocks, avg, peak, budget;
  const LoadReading(this.blocks, this.avg, this.peak, this.budget);
  double get avgPct => budget > 0 ? 100 * avg / budget : 0;
  double get peakPct => budget > 0 ? 100 * peak / budget : 0;
}

/// "synth blocks N avg A peak P budget B cycles"
LoadReading? parseLoad(String line) {
  final m = RegExp(r'synth blocks (\d+) avg (\d+) peak (\d+) budget (\d+)').firstMatch(line);
  if (m == null) return null;
  return LoadReading(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!));
}

/// `"params <target> <name> <count>"  (name may contain spaces, e.g. "modal:wine glass")`
({int target, String name, int count})? parseParamsHeader(String line) {
  final m = RegExp(r'^params ([0-3]) (.+) (\d+)\s*$').firstMatch(line);
  return m == null ? null : (target: int.parse(m[1]!), name: m[2]!, count: int.parse(m[3]!));
}

/// One live parameter as the board lists it.
class Param {
  final int index;
  final String name, group;
  final double min, max;
  final int kind;
  double value;
  double loadValue;
  Param({required this.index, required this.name, required this.group, required this.min, required this.max, required this.value, required this.kind})
      : loadValue = value;
  Param copy() => Param(index: index, name: name, group: group, min: min, max: max, value: value, kind: kind)..loadValue = loadValue;
}

final _paramLine = RegExp(r'^(\d+) (\S+) (\S+) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) (\d+)\s*$');

/// "i name group minhex maxhex valuehex kind"
Param? parseParamLine(String line) {
  final m = _paramLine.firstMatch(line);
  if (m == null) return null;
  return Param(
    index: int.parse(m[1]!), name: m[2]!, group: m[3]!,
    min: hexToFloat(m[4]!), max: hexToFloat(m[5]!), value: hexToFloat(m[6]!), kind: int.parse(m[7]!),
  );
}

({int target, int index})? parseQErr(String line) {
  final m = RegExp(r'^Q err (\d+) (\d+)').firstMatch(line);
  return m == null ? null : (target: int.parse(m[1]!), index: int.parse(m[2]!));
}

class VersionInfo {
  final String line, fw;
  List<String> extra = const [];
  VersionInfo(this.line, this.fw);
}

/// The first line of the V reply: `striso_control_<board>_v2.2.4 <uid> <id>`.
VersionInfo parseVersion(String line) {
  final m = RegExp(r'(\S*_v[\w.\-]+)').firstMatch(line);
  final t = line.trim();
  final fw = m != null ? m[1]!.replaceFirst(RegExp('^striso_control_'), '') : (t.isEmpty ? '' : t.split(RegExp(r'\s+')).first);
  return VersionInfo(t, fw);
}

/// Clamp and round a value the way the firmware does before writing it (apply_params).
double conformValue(Param p, double v) => conformTo(p.min, p.max, p.kind, v, p.value);

double conformTo(double min, double max, int kind, double v, double fallback) {
  if (!v.isFinite) return fallback;
  v = v < min ? min : (v > max ? max : v);
  if (kind != Kind.continuous) v = (v + (v >= 0 ? 0.5 : -0.5)).truncateToDouble();
  return toFloat32(v);
}
