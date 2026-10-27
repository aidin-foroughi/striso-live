// The voice keys (Stca, StcA): the replies as the firmware writes them
// (striso-control-firmware virtual/tests/transcripts/voice_keys.txt) and the save that writes the
// board's edits as they are. The client against the board's voice keys:
// packages/striso_virtual/test/voice_keys_test.dart.

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
}
