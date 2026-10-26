// The voice keys (Stca, StcA): the replies as the firmware writes them
// (striso-control-firmware virtual/tests/transcripts/voice_keys.txt), the client against the mock,
// and the save that writes the board's edits as they are.
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

// the firmware's Stca after "bowed:cello on key 12, key 24 cleared" (its transcript)
const firmwareStca = [
  'a slots 12',
  'a 10 empty - - - - - - -',
  'a 12 ok 400000 bowed cello 15 9 17 -',
  'a 13 ok 402800 brass - 47 9 47 brass',
  'a 14 empty - - - - - - -',
  'a 15 ok 003030 trumpet - 56 1 56 trumpet',
  'a 16 ok 401024 accordion - 57 9 57 accordion',
  'a 18 ok 282828 strisy - 0 1 0 strisy',
  'a 20 ok 401400 va - 1 8 1 va',
  'a 22 ok 001840 modal - 9 6 9 modal',
  'a 24 empty - - - - - - bowed',
  'a 26 missing - sax - - - - wind',
  'a 28 ok 280040 ep - 33 14 33 ep',
  'a set sGv12a bowed',
  'a set sGv12p cello',
  'a blank sGv24a',
  'a set sGv26a sax',
  'a end',
];

void main() {
  test('Stca as the firmware writes it: the keys, their states, the edits', () {
    final vk = parseVoiceKeys(firmwareStca)!;
    expect(vk.slots.length, 12);
    final k12 = vk[12]!;
    expect(k12.state, 'ok');
    expect(k12.plays, isTrue);
    expect(k12.colour, 0x400000);
    expect(k12.engine, 'bowed');
    expect(k12.preset, 'cello');
    expect((k12.first, k12.count, k12.at), (15, 9, 17));
    expect(k12.factory, isNull);
    expect(k12.isFactory, isFalse);
    expect(vk[24]!.empty, isTrue);
    expect(vk[24]!.factory, 'bowed');
    expect(vk[26]!.missing, isTrue);
    expect(vk[26]!.engine, 'sax');
    expect(vk[26]!.colour, isNull);
    expect(vk[18]!.isFactory, isTrue);
    expect(vk.keysOf('bowed'), [12]);
    expect(vk.saved, isFalse);
    expect(vk.edits.map((e) => '$e'), ['a set sGv12a bowed', 'a set sGv12p cello', 'a blank sGv24a', 'a set sGv26a sax']);
    // the lines read back as they came
    expect(vk.slots.map((s) => '$s'), firmwareStca.sublist(1, 13));
    // a cut reply is none
    expect(parseVoiceKeys(firmwareStca.sublist(0, 5)), isNull);
    expect(parseVoiceKeys([...firmwareStca.sublist(0, 3), 'a end']), isNull);
  });

  test('StcA replies', () {
    final ok = parseVoiceKeyReply('A ok 12 bowed cello')!;
    expect((ok.ok, ok.key, ok.engine, ok.preset), (true, 12, 'bowed', 'cello'));
    final none = parseVoiceKeyReply('A ok 24 - -')!;
    expect((none.ok, none.engine, none.preset), (true, null, null));
    final err = parseVoiceKeyReply('A err entry 12')!;
    expect((err.ok, err.key, err.why), (false, 12, 'entry'));
    expect(parseVoiceKeyReply('K ok 12'), isNull);
    expect(voiceKeyCommand(12, 0x1234), [0x53, 0x74, 0x63, 0x41, 12, 0x34, 0x12]);
    expect(() => voiceKeyCommand(12, 0x10000), throwsRangeError);
  });

  test('the client against the mock: put on a key, clear it, its factory engine; errors', () async {
    final t = MockTransport();
    final c = StrisoClient(t);
    await c.connect();
    final vk0 = (await c.getVoiceKeys())!;
    expect(vk0.saved, isTrue);
    expect(vk0[15]!.engine, 'trumpet');
    expect(vk0[12]!.empty, isTrue);
    final voices = await c.listVoices();
    final modal = voices.firstWhere((v) => v.engine == 'modal' && v.preset != null && !v.preset!.contains(' '));
    final a = (await c.assignVoiceKey(12, modal.index))!;
    expect((a.ok, a.engine, a.preset), (true, 'modal', modal.preset));
    final vk1 = (await c.getVoiceKeys())!;
    expect(vk1[12]!.engine, 'modal');
    expect(vk1[12]!.plays, isTrue);
    expect(vk1.edits.map((e) => e.key), containsAll(['sGv12a', 'sGv12p']));
    expect((await c.assignVoiceKey(15, voiceKeyClear))!.ok, isTrue);
    expect((await c.getVoiceKeys())![15]!.empty, isTrue);
    expect((await c.getVoiceKeys())!.edits.map((e) => '$e'), contains('a blank sGv15a'));
    expect((await c.assignVoiceKey(15, voiceKeyFactory))!.engine, 'trumpet');
    expect((await c.assignVoiceKey(17, 0))!.why, 'key');
    expect((await c.assignVoiceKey(12, 9999))!.why, 'entry');
    await c.disconnect();
  });

  test('the save writes the board\'s voice-key edits as they are, and only voice-key records', () {
    final values = TouchValues(
      [('pressure', 1.0), ('velocity', 1.0), ('tilt', 1.0), ('bend', 0.25), ('threshold', 0.0)],
      [for (final n in keyNamesForTest()) (n, 1.0)],
    );
    final current = configUf2([('sGv13a', 'sax'), ('iGoct', '1')]);
    final edits = parseVoiceKeys(firmwareStca)!.edits;
    final built = buildConfig(current, values, voiceKeys: [...edits, const ConfigEdit('default', 'sGv13a')]);
    final recs = {for (final (k, v) in configParse(built.data)) k.trim(): v.trim()};
    expect(recs['sGv12a'], 'bowed');
    expect(recs['sGv12p'], 'cello');
    expect(recs.containsKey('sGv24a'), isTrue);
    expect(recs['sGv24a'], '', reason: 'blank: cleared, not the default');
    expect(recs.containsKey('sGv13a'), isFalse, reason: 'default: the record dropped');
    expect(recs['iGoct'], '1', reason: 'the rest stays');
    expect(() => buildConfig(current, values, voiceKeys: [const ConfigEdit('set', 'iGpreset', '3')]), throwsA(isA<ConfigError>()));
    expect(() => buildConfig(current, values, voiceKeys: [const ConfigEdit('drop', 'sGv12a')]), throwsA(isA<ConfigError>()));
    expect(built.data, isA<Uint8List>());
  });
}

// the 61 key names (F_1 .. B_4) as the board lists its key factors
List<String> keyNamesForTest() {
  const notes = ['C_', 'Db', 'C#', 'D_', 'Eb', 'D#', 'E_', 'F_', 'Gb', 'F#', 'G_', 'Ab', 'G#', 'A_', 'Bb', 'A#', 'B_'];
  return [for (var n = 0; n < 61; n++) '${notes[(n + 7) % 17]}${(n + 7) ~/ 17 + 1}'];
}
