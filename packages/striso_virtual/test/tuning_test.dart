// striso_core's client against the virtual board's settings keys (StcK) and its tuning (StcN): the
// keys switch the tuning, the MIDI mode, a settings preset and the voice as the board's settings
// layout (StcX) says, and are refused where it says they don't switch; the tuning read back is
// named from that layout. The tuning reply's parsing and the quarter-tone notation: striso_core's
// test/tuning_test.dart.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/board.dart';

void main() {
  group('settings keys and tunings on the virtual board', skip: libraryMissing, () {
    test('the client reads the board\'s tuning, named by its settings layout', () async {
      final (b, c) = await boot();
      final layout = (await c.getSettingsLayout())!;
      final pyth = layout.keys.entries.firstWhere((e) => e.value.tuningIndex == 3);
      expect((await c.pressSettingsKey(pyth.key))!.ok, isTrue);
      final t = (await c.getTuning())!;
      expect(t.complete, isTrue);
      expect(t.index, 3);
      expect(t.nameIn(layout).name, pyth.value.title.substring('Tuning 3: '.length));
      expect(t.nameIn(layout).name, 'Pythagorean');
    });

    test('the keys switch tuning, MIDI mode, preset and voice; dials, actions and keys without a function are refused', () async {
      final (b, c) = await boot();
      final layout = (await c.getSettingsLayout())!;
      int tuningKey(int n) => layout.keys.entries.firstWhere((e) => e.value.tuningIndex == n).key;
      expect(await c.pressSettingsKey(tuningKey(1)), (ok: true, id: tuningKey(1)));
      expect((await c.getState())!.tuning, 1);
      expect((await c.getTuning())!.nameIn(layout).name, '31-TET');
      expect(await c.pressSettingsKey(tuningKey(0)), (ok: true, id: tuningKey(0)));
      expect((await c.getState())!.tuning, 0);
      // MIDI mono (key 4 on the settings card)
      expect(layout[4]!.group, SettingsGroup.midi);
      expect(await c.pressSettingsKey(4), (ok: true, id: 4));
      expect((await c.getState())!.midi, 'midimono');
      // a settings preset
      final preset = layout.keys.entries.firstWhere((e) => e.value.group == SettingsGroup.preset).key;
      expect(await c.pressSettingsKey(preset), (ok: true, id: preset));
      // a voice key: its engine plays
      final (vk, engine, _) = layout.voiceKeys.firstWhere((v) => v.$2 != 'va');
      final voices = await c.listVoices();
      expect(await c.pressSettingsKey(vk), (ok: true, id: vk));
      await until(() => voices[b.state.voice].engine == engine);
      // panic
      expect(await c.pressSettingsKey(63), (ok: true, id: 63));
      // refused: what the layout says doesn't switch, and a key without a settings function
      for (final e in layout.keys.entries.where((e) => !e.value.switchable)) {
        expect(await c.pressSettingsKey(e.key), (ok: false, id: e.key), reason: '${e.key} ${e.value.title}');
      }
      final none = keyIds.firstWhere((id) => layout[id] == null);
      expect(await c.pressSettingsKey(none), (ok: false, id: none));
    });
  });
}
