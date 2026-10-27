// The board's sound presets on the console (doc/presets_console.md): the replies parsed as the
// spec writes them. The client against the board's presets: packages/striso_virtual/test/presets_test.dart.
import 'dart:convert';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

void main() {
  group('the replies', () {
    test('J: factory then user, a description after |, unreadable, store off', () {
      final l = parsePresetList([
        'J 32768 strisy - strisy|',
        'J 33025 va - pad|',
        'J 3 va v2.2.4-340 Warm pad|Slow attack | dark.',
        'J 4 ? - (unreadable)|',
        'J end 4',
      ])!;
      expect(l.storeOn, isTrue);
      expect(l.presets.map((p) => p.id), [32768, 33025, 3, 4]);
      expect(l.presets[1].factory, isTrue);
      expect(l.presets[1].version, isNull);
      expect(l.presets[2].title, 'Warm pad');
      expect(l.presets[2].description, 'Slow attack | dark.', reason: 'the rest of the line, | and all');
      expect(l.presets[1].description, isNull);
      expect(l.presets[2].version, 'v2.2.4-340');
      expect(l.presets[3].readable, isFalse);
      expect(parsePresetList(['J 1 va - x', 'J store off', 'J end 1'])!.storeOn, isFalse);
      expect(parsePresetList(['J 1 va - x']), isNull, reason: 'cut short');
    });

    test('O: exact, the report with its names, errors', () {
      final e = parseOpenReport(['O ok 33025 voice 2 exact'])!;
      expect(e.exact, isTrue);
      expect(e.voice, 2);
      final lines = ['O ok 3 voice 2 clamped 2 skipped 1 missing 4', 'O clamped gain cutoff', 'O skipped old_knob'];
      expect(openDone(lines.take(1).toList()), isFalse, reason: 'the names follow');
      expect(openDone(lines), isTrue);
      final r = parseOpenReport(lines)!;
      expect((r.clamped, r.skipped, r.missing), (2, 1, 4));
      expect(r.clampedNames, ['gain', 'cutoff']);
      expect(r.skippedNames, ['old_knob']);
      final err = parseOpenReport(['O err engine flute'])!;
      expect(err.ok, isFalse);
      expect(err.why, 'engine flute');
    });

    test('j: the text as stored, its final newline from the byte count; errors', () {
      final t = parsePresetText(['j 3 10', '{"a": 1', '}', 'j end'])!;
      expect(t.text, '{"a": 1\n}\n');
      expect(parsePresetText(['j 3 9', '{"a": 1', '}', 'j end'])!.text, '{"a": 1\n}');
      expect(parsePresetText(['j err factory 33025'])!.why, 'factory 33025');
    });

    test('the commands: two-byte ids, an upload with its length', () {
      expect(presetOpenCommand(33025), [0x53, 0x74, 0x63, 'O'.codeUnitAt(0), 0x01, 0x81]);
      final up = presetUploadCommand(1, utf8.encode('Pad'));
      expect(up.sublist(0, 9), [0x53, 0x74, 0x63, 'F'.codeUnitAt(0), 1, 3, 0, 0, 0]);
      expect(presetDeleteCommand(3), [0x53, 0x74, 0x63, 'x'.codeUnitAt(0), 3, 0]);
      expect(utf8.decode(up.sublist(9)), 'Pad');
      expect(jsonDecode(utf8.decode(saveAsBytes(' Pad ', ' Dark. '))), {'title': 'Pad', 'description': 'Dark.'});
      expect(() => presetDeleteCommand(0), throwsRangeError);
    });
  });
}
