// striso_core's client against the virtual board's voice keys (Stca, StcA): a built-in engine's
// preset put on a free key, a factory key cleared and given its factory engine back, the edits the
// board lists for the save; the board's refusals. An engine from a slot on a key and the save
// through the board's drive: virtual_board_test.dart. The reply formats: striso_core's
// test/voice_keys_test.dart.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  test('voice keys on the virtual board: put on a key, clear it, its factory engine; refusals', skip: libraryMissing, () async {
    final (b, c) = await boot();
    final vk0 = (await c.getVoiceKeys())!;
    expect(vk0.saved, isTrue, reason: 'factory settings: nothing to save');
    final free = vk0.slots.firstWhere((s) => s.empty).key;
    final factory = vk0.slots.firstWhere((s) => s.factory != null && s.isFactory && s.factory != 'strisy');
    final voices = await c.listVoices();
    final modal = voices.firstWhere((v) => v.engine == 'modal' && v.preset != null && !v.preset!.contains(' '));
    final a = (await c.assignVoiceKey(free, modal.index))!;
    expect((a.ok, a.key, a.engine, a.preset), (true, free, 'modal', modal.preset));
    final vk1 = (await c.getVoiceKeys())!;
    expect(vk1[free]!.engine, 'modal');
    expect(vk1[free]!.plays, isTrue);
    expect(vk1.edits.map((e) => e.key), containsAll(['sGv${free}a', 'sGv${free}p']));
    expect((await c.assignVoiceKey(factory.key, voiceKeyClear))!.ok, isTrue);
    final vk2 = (await c.getVoiceKeys())!;
    expect(vk2[factory.key]!.empty, isTrue);
    expect(vk2.edits.map((e) => '$e'), contains('a blank sGv${factory.key}a'));
    expect((await c.assignVoiceKey(factory.key, voiceKeyFactory))!.engine, factory.engine);
    // refused: a key that holds no voice, an entry that isn't there
    final notAVoiceKey = (await c.getKeyLayout())!.keyIds.firstWhere((id) => vk0[id] == null);
    expect((await c.assignVoiceKey(notAVoiceKey, 0))!.why, 'key');
    expect((await c.assignVoiceKey(free, voices.length + 100))!.why, 'entry');
  });
}
