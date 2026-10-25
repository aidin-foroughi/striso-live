// The board's sound presets on the console (doc/presets_console.md): the replies parsed as the
// spec writes them, and the client against the mock that answers them.
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

  group('the client on the mock', () {
    late MockBoard board;
    late StrisoClient c;
    setUp(() async {
      board = MockBoard(autoplay: false, idleFrames: 0);
      c = StrisoClient(MockTransport(board: board));
      await c.connect();
    });
    tearDown(() => c.disconnect());

    test('save as, list, read back, open, delete', () async {
      final voices = await c.listVoices();
      final pad = voices.firstWhere((v) => v.name == 'va:pad');
      await c.selectVoice(pad.index);
      final l = (await c.listPresets())!;
      expect(l.presets.length, voices.length, reason: 'the factory presets are the voice entries');
      expect(l.presets.firstWhere((p) => p.title == 'pad' && p.engine == 'va').id, 33025, reason: 'the spec\'s example id');
      final saved = (await c.savePresetAs('Warm pad', 'Slow attack, dark.'))!;
      expect(saved.ok, isTrue);
      final mine = (await c.listPresets())!.user.single;
      expect((mine.id, mine.engine, mine.title, mine.description), (saved.id, 'va', 'Warm pad', 'Slow attack, dark.'));
      final text = (await c.presetText(saved.id!))!.text!;
      expect(describePresetFile(text).title, 'Warm pad');
      expect(describePresetFile(text).engine, 'va');
      await c.selectVoice(0);
      final o = (await c.openPreset(saved.id!))!;
      expect(o.ok, isTrue);
      expect(o.exact, isTrue);
      expect(o.voice, voices.firstWhere((v) => v.engine == 'va').index, reason: 'its engine\'s first voice');
      expect((await c.deletePreset(saved.id!))!.ok, isTrue);
      expect((await c.listPresets())!.user, isEmpty);
      expect((await c.deletePreset(saved.id!))!.why, 'no preset ${saved.id}');
      expect((await c.deletePreset(33025))!.why, 'factory 33025');
    });

    test('install: a file from elsewhere loads by name, with what was clamped and skipped', () async {
      final file = jsonEncode({
        'format': 'awva-preset/1',
        'engine': {'id': 'va', 'version': 'v2.2.4-200', 'params_hash': '00000000'},
        'title': 'From an older va',
        'params': {'gain': 99, 'release': 0.3, 'old_knob': 1},
      });
      final r = (await c.installPreset(utf8.encode(file)))!;
      expect(r.ok, isTrue);
      expect((await c.presetText(r.id!))!.text, file, reason: 'stored byte for byte');
      final o = (await c.openPreset(r.id!))!;
      expect(o.ok, isTrue);
      expect(o.exact, isFalse);
      expect(o.clampedNames, ['gain']);
      expect(o.skippedNames, ['old_knob']);
      expect(o.missing, greaterThan(0));
      // refused, with the board's reason
      expect((await c.installPreset(utf8.encode('{not json')))!.why, 'syntax');
      expect((await c.installPreset(utf8.encode(file.replaceAll('"va"', '"flute"'))))!.why, 'engine flute');
      expect((await c.installPreset(const []))!.why, 'empty');
      expect((await c.savePresetAs('x' * 64, ''))!.why, 'fields');
      expect((await c.presetText(32768))!.why, 'no text 32768', reason: 'strisy has no presets');
      expect(describePresetFile((await c.presetText(33025))!.text!).title, 'pad', reason: 'a factory preset\'s text');
    });

    test('the store off: factory presets only, the user\'s commands say so', () async {
      board.presetStore = false;
      final l = (await c.listPresets())!;
      expect(l.storeOn, isFalse);
      expect(l.user, isEmpty);
      expect((await c.savePresetAs('x', ''))!.why, 'store off');
      expect((await c.openPreset(33025))!.ok, isTrue, reason: 'a factory preset still opens');
    });
  });
}
