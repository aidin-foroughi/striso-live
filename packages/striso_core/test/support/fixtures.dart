// The firmware's console replies recorded from the virtual board (test/fixtures/*.txt, written by
// packages/striso_virtual/tool/record_fixtures.dart): `#` header lines (the firmware they came
// from), then sections `[name] > command` followed by the board's reply lines.
import 'dart:io';

import 'package:striso_core/striso_core.dart';

import 'firmware.dart';

class Fixture {
  /// The firmware the replies came from (its version line).
  final String firmware;
  final Map<String, List<String>> sections;
  const Fixture(this.firmware, this.sections);

  /// The reply lines of section [name].
  List<String> operator [](String name) => sections[name] ?? (throw ArgumentError('no section [$name] in the fixture'));
}

final _section = RegExp(r'^\[([^\]]+)\] > ');

Fixture readFixture(String file) {
  final root = repoRoot() ?? (throw StateError('not in the striso-live repository'));
  final lines = File('${root.path}/packages/striso_core/test/fixtures/$file').readAsLinesSync();
  var firmware = '';
  final sections = <String, List<String>>{};
  List<String>? cur;
  for (final l in lines) {
    final m = _section.firstMatch(l);
    if (m != null) {
      cur = sections[m.group(1)!] = [];
    } else if (cur != null) {
      cur.add(l);
    } else if (l.startsWith('# firmware: ')) {
      firmware = l.substring('# firmware: '.length);
    }
  }
  if (firmware.isEmpty) throw StateError('$file names no firmware');
  return Fixture(firmware, sections);
}

/// The board's key layout as the firmware reports it (StcG, test/fixtures/key_layout.txt).
KeyLayout fixtureKeyLayout() => parseKeyLayout(readFixture('key_layout.txt')['G'])!;
