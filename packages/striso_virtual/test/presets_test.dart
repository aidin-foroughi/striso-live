// striso_core's client against the virtual board's sound presets (doc/presets_console.md): save
// as, list, read back, open, delete; a preset file from elsewhere installed and opened by name,
// with what the board clamped and skipped; the board's refusals in its own words. The reply
// formats: striso_core's test/presets_test.dart.
import 'dart:convert';

import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  group('presets on the virtual board', skip: libraryMissing, () {
    late VirtualBoard b;
    late StrisoClient c;
    setUp(() async => (b, c) = await boot());

    test('save as, list, read back, open, delete', () async {
      final voices = await c.listVoices();
      final pad = voices.firstWhere((v) => v.name == 'va:pad');
      await c.selectVoice(pad.index);
      final l = (await c.listPresets())!;
      expect(l.storeOn, isTrue);
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
      expect(b.state.voice, o.voice);
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
  });
}
