// The hero knobs: the six to eight parameters that shape each engine's sound most, by the names in
// the firmware's parameter tables (striso-control-firmware voice_*.h, fx.h; test/hero_test.dart
// checks them against the source), with overrides for presets whose character lives elsewhere.

import 'protocol.dart';

/// Per engine, in display order.
const Map<String, List<String>> heroParams = {
  'va': ['cut_base', 'res', 'cut_env', 'drive', 'saw2_detune', 'sub', 'release', 'vibrato'],
  'bowed': ['force_hi', 'pos', 'rosin', 'bright', 'body_amt', 'damp', 'vibrato', 'ensemble'],
  'modal': ['hard', 'decay', 'upper', 'keytrack', 'hfdamp', 'damper', 'tremdepth', 'rub'],
  'wind': ['reed_open', 'attack', 'bright', 'breath', 'growl', 'vib', 'body', 'tongue'],
  'brass': ['brassiness', 'lip_loud', 'tone_hz', 'breath', 'mute', 'release', 'vibrato', 'pair'],
  'ep': ['hard', 'decay', 'bell', 'tick', 'drive', 'grit', 'tone', 'wobble'],
};

/// Per preset (the voice name as the board lists it), when it differs from its engine's.
const Map<String, List<String>> heroPresetParams = {
  'va:pad': ['cut_base', 'cut_env', 'release', 'saw2_detune', 'drift', 'res', 'sub', 'vibrato'],
  'va:bass': ['cut_base', 'res', 'cut_env', 'drive', 'sub', 'acc_level', 'acc_cutoff', 'release'],
  'va:acid': ['cut_base', 'res', 'cut_env', 'drive', 'acc_cutoff', 'acc_level', 'acc_decay', 'release'],
  'bowed:pizzicato': ['pizz_decay', 'pizz_bright', 'pos', 'bright', 'body_amt', 'damp', 'rel', 'vibrato'],
  'bowed:section': ['ensemble', 'ens_detune', 'ens_spread', 'force_hi', 'pos', 'bright', 'body_amt', 'vibrato'],
  'brass:harmon': ['mute', 'mute_bp', 'mute_hz', 'wah', 'brassiness', 'tone_hz', 'vibrato', 'release'],
  'brass:plunger': ['mute', 'mute_lp', 'mute_hz', 'wah', 'brassiness', 'tone_hz', 'vibrato', 'release'],
  'brass:section': ['pair', 'detune', 'brassiness', 'lip_loud', 'tone_hz', 'breath', 'vibrato', 'release'],
  'ep:wurli': ['wurli', 'hard', 'decay', 'drive', 'grit', 'tone', 'wobble', 'dyn'],
  'wind:flute': ['jet', 'jet_off', 'breath', 'turb', 'bright', 'attack', 'vib', 'body'],
};

/// The effect amounts on the Play tab (firmware fx.h names).
const List<String> heroFxParams = ['rvmix', 'dlmix'];

/// The hero knobs of a voice: the preset's or the engine's names that this voice lists; when
/// none match (another firmware, the demo board), the first [count] continuous parameters in
/// group order.
List<Param> heroKnobs(String voiceName, List<Param> params, {int count = 8}) {
  final engine = voiceName.split(':').first;
  final names = heroPresetParams[voiceName] ?? heroParams[engine] ?? const <String>[];
  final out = <Param>[];
  for (final n in names) {
    final p = params.where((q) => q.name == n).firstOrNull;
    if (p != null) out.add(p);
    if (out.length >= count) break;
  }
  if (out.length >= 4) return out;
  return [...out, ...params.where((p) => p.kind == Kind.continuous && !out.contains(p))].take(count).toList();
}

/// The reverb and delay amounts, by the firmware's names or the demo board's.
List<Param> heroFx(List<Param> params) {
  final out = <Param>[];
  for (final names in const [
    ['rvmix', 'rv_mix'],
    ['dlmix', 'dl_mix'],
  ]) {
    final p = params.where((q) => names.contains(q.name)).firstOrNull;
    if (p != null) out.add(p);
  }
  return out;
}
