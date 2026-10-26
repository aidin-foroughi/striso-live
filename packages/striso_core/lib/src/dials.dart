// The settings dials set from the console (StcT, striso-control-firmware doc/dials_console.md): the
// board lists its dials with their ranges (StcT 255), a dial is set to a value it clamps to its own
// range and steps, and answers with the value it took. The app shows the board's list and values;
// it keeps no ranges of its own.
//
//   StcT <dial:1> <value:float32 LE>  ->  T <name> <value> | T err <dial>
//   StcT 255                          ->  T dial <n> <name> <min> <max> <step>
//                                         T dial <n> <name> values <v> <v> ...
//                                         T end

import 'dart:typed_data';

/// The list request's dial number.
const dialListId = 255;

Uint8List dialSetCommand(int dial, double value) {
  if (dial < 0 || dial > 255) throw RangeError('bad dial $dial');
  final b = ByteData(4)..setFloat32(0, value, Endian.little);
  return Uint8List.fromList([0x53, 0x74, 0x63, 0x54, dial, ...b.buffer.asUint8List()]);
}

Uint8List dialListCommand() => dialSetCommand(dialListId, 0);

/// A dial as the board lists it: its number, its StcY name, and its range: [min]..[max] in steps
/// of [step], or one of [values].
class DialInfo {
  final int id;
  final String name;
  final double min, max, step;
  final List<double>? values;
  const DialInfo(this.id, this.name, {required this.min, required this.max, this.step = 0, this.values});

  /// How many positions a slider of it has (null: continuous).
  int? get divisions {
    final v = values;
    if (v != null) return v.length > 1 ? v.length - 1 : null;
    if (step <= 0) return null;
    final n = ((max - min) / step).round();
    return n > 0 && n <= 2000 ? n : null;
  }

  @override
  String toString() => values != null ? 'T dial $id $name values ${values!.join(' ')}' : 'T dial $id $name $min $max $step';
}

final _dialLine = RegExp(r'^T dial (\d+) (\S+) (.+)$');

bool isDialLine(String l) => l.trim().startsWith('T ');

/// The StcT 255 reply; null when it is not a whole one.
List<DialInfo>? parseDialList(List<String> lines) {
  final out = <DialInfo>[];
  for (final raw in lines) {
    final l = raw.trim();
    if (l == 'T end') return out;
    final m = _dialLine.firstMatch(l);
    if (m == null) continue;
    final rest = m[3]!.split(' ');
    final id = int.parse(m[1]!), name = m[2]!;
    if (rest.first == 'values') {
      final v = [for (final x in rest.skip(1)) ?double.tryParse(x)];
      if (v.isEmpty) continue;
      out.add(DialInfo(id, name, min: v.first, max: v.last, values: v));
    } else if (rest.length == 3) {
      final n = [for (final x in rest) double.tryParse(x)];
      if (n.contains(null)) continue;
      out.add(DialInfo(id, name, min: n[0]!, max: n[1]!, step: n[2]!));
    }
  }
  return null;
}

/// A set reply: the dial's name and the value it took, or the refused dial.
({String? name, double? value, int? refused})? parseDialReply(String line) {
  final l = line.trim();
  final err = RegExp(r'^T err (\d+)$').firstMatch(l);
  if (err != null) return (name: null, value: null, refused: int.parse(err[1]!));
  final m = RegExp(r'^T (\S+) (-?[\d.]+)$').firstMatch(l);
  if (m == null || m[1] == 'dial' || m[1] == 'end') return null;
  return (name: m[1], value: double.tryParse(m[2]!), refused: null);
}
