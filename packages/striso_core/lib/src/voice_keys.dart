// The voice keys as the firmware reports them (Stca, src/synth/voice_keys.hpp): which engine is on
// each voice key, by the engine's id, and whether the voice list has it; then the config edits that
// would keep the keys as they are now (Save to Striso writes them as they are). The app shows this
// and changes it with StcA; it decides nothing about it itself.
//
//   a slots <n>
//   a <key> <state> <colour|-> <engine|-> <preset|-> <first|-> <count|-> <at|-> <factory|->
//   a set <config key> <value> | a blank <config key> | a default <config key>
//   a end

/// One voice key.
class VoiceKeySlot {
  /// The settings key.
  final int key;

  /// ok, preset (the preset it names isn't the engine's: it starts on the first), missing (its
  /// engine isn't in the voice list: the key shows that and plays nothing), empty.
  final String state;

  /// The engine's colour (0xRRGGBB), null unless it plays.
  final int? colour;

  /// The engine's id, null when the key has none.
  final String? engine;

  /// The preset it names, null: the engine's first.
  final String? preset;

  /// The engine's voice entries (Stcv) and the one the key selects now; null unless it plays.
  final int? first, count, at;

  /// The key's engine in the board's defaults, null: none.
  final String? factory;

  const VoiceKeySlot(this.key, this.state, {this.colour, this.engine, this.preset, this.first, this.count, this.at, this.factory});

  bool get plays => state == 'ok' || state == 'preset';
  bool get missing => state == 'missing';
  bool get empty => state == 'empty';

  /// The key holds what the defaults give it (engine and preset).
  bool get isFactory => engine == factory && preset == null;

  @override
  String toString() =>
      'a $key $state ${colour == null ? '-' : colour!.toRadixString(16).padLeft(6, '0')} ${engine ?? '-'} ${preset ?? '-'} '
      '${first ?? '-'} ${count ?? '-'} ${at ?? '-'} ${factory ?? '-'}';
}

/// A config edit the board lists for a save: set (write the value), blank (write a blank value),
/// default (drop the user's record).
class ConfigEdit {
  final String kind, key, value;
  const ConfigEdit(this.kind, this.key, [this.value = '']);
  @override
  String toString() => 'a $kind $key${kind == 'set' ? ' $value' : ''}';
}

class VoiceKeys {
  final List<VoiceKeySlot> slots;
  final List<ConfigEdit> edits;
  const VoiceKeys(this.slots, this.edits);

  static const empty = VoiceKeys([], []);

  VoiceKeySlot? operator [](int key) => slots.where((s) => s.key == key).firstOrNull;

  /// The keys an engine is on, in key order.
  List<int> keysOf(String engine) => [
    for (final s in slots)
      if (s.engine == engine) s.key,
  ]..sort();

  /// Nothing to write for a save (the settings already hold the keys).
  bool get saved => edits.isEmpty;
}

final _head = RegExp(r'^a slots (\d+)$');
final _slot = RegExp(r'^a (\d+) (ok|preset|missing|empty|\w+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)$');
final _edit = RegExp(r'^a (set|blank|default) (\S+)(?: (\S+))?$');

/// The Stca reply's lines; null when it is not a whole one.
VoiceKeys? parseVoiceKeys(List<String> lines) {
  int? n;
  final slots = <VoiceKeySlot>[];
  final edits = <ConfigEdit>[];
  var ended = false;
  String? s(String v) => v == '-' ? null : v;
  int? i(String v) => v == '-' ? null : int.tryParse(v);
  for (final raw in lines) {
    final l = raw.trim();
    final h = _head.firstMatch(l);
    if (h != null) {
      n = int.parse(h.group(1)!);
      continue;
    }
    if (l == 'a end') {
      ended = true;
      break;
    }
    final e = _edit.firstMatch(l);
    if (e != null) {
      edits.add(ConfigEdit(e.group(1)!, e.group(2)!, e.group(3) ?? ''));
      continue;
    }
    final m = _slot.firstMatch(l);
    if (m == null) continue;
    slots.add(
      VoiceKeySlot(
        int.parse(m.group(1)!),
        m.group(2)!,
        colour: m.group(3) == '-' ? null : int.tryParse(m.group(3)!, radix: 16),
        engine: s(m.group(4)!),
        preset: s(m.group(5)!),
        first: i(m.group(6)!),
        count: i(m.group(7)!),
        at: i(m.group(8)!),
        factory: s(m.group(9)!),
      ),
    );
  }
  if (n == null || !ended || slots.length != n) return null;
  return VoiceKeys(slots, edits);
}

/// StcA's reply: `A ok <key> <engine|-> <preset|->` or `A err <why> <key>`.
class VoiceKeyReply {
  final bool ok;
  final int key;
  final String? engine, preset, why;
  const VoiceKeyReply.ok(this.key, this.engine, this.preset) : ok = true, why = null;
  const VoiceKeyReply.err(this.key, this.why) : ok = false, engine = null, preset = null;
}

final _aOk = RegExp(r'^A ok (\d+) (\S+) (\S+)$');
final _aErr = RegExp(r'^A err (\S+) (\d+)$');

VoiceKeyReply? parseVoiceKeyReply(String line) {
  final l = line.trim();
  final o = _aOk.firstMatch(l);
  if (o != null) {
    String? s(String v) => v == '-' ? null : v;
    return VoiceKeyReply.ok(int.parse(o.group(1)!), s(o.group(2)!), s(o.group(3)!));
  }
  final e = _aErr.firstMatch(l);
  if (e != null) return VoiceKeyReply.err(int.parse(e.group(2)!), e.group(1));
  return null;
}

/// StcA's entry for "no engine" and for "the key's factory engine".
const voiceKeyClear = 0xFFFF, voiceKeyFactory = 0xFFFE;
