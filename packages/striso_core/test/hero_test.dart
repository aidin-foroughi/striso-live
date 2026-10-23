// The hero knob names against the firmware's parameter tables, and the fallbacks.
import 'dart:io';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/firmware.dart';

/// Parameter names declared in a firmware header: {"name", "group", min, max, kind}.
Set<String> declared(File f) => {for (final m in RegExp(r'\{\s*"([a-z0-9_]+)",\s*"([a-z_]+)",').allMatches(f.readAsStringSync())) m[1]!};

Param p(String name, [int kind = 0]) => Param(index: 0, name: name, group: 'g', min: 0, max: 1, value: 0.5, kind: kind);

/// The header of each engine with hero knobs.
const engineFiles = {
  'va': 'voice_va.h',
  'bowed': 'voice_bowed.h',
  'modal': 'voice_modal.h',
  'wind': 'voice_wind.h',
  'brass': 'voice_brass.h',
  'ep': 'voice_ep.h',
  'trumpet': 'voice_trumpet.h',
};

/// Engines newer than some firmware checkouts: checked when their header is there.
const newerEngines = {'trumpet'};

void main() {
  final fw = firmwareDir();

  void checkEngine(String engine) {
    final f = firmwareFile(engineFiles[engine]!)!;
    final have = declared(f);
    for (final n in heroParams[engine]!) {
      expect(have, contains(n), reason: '$engine: $n (${f.path})');
    }
    for (final MapEntry(key: voice, value: names) in heroPresetParams.entries.where((e) => e.key.split(':').first == engine)) {
      for (final n in names) {
        expect(have, contains(n), reason: '$voice: $n (${f.path})');
      }
    }
  }

  test('every hero name is a parameter of its engine in the firmware', () {
    for (final engine in heroParams.keys.where((e) => !newerEngines.contains(e))) {
      checkEngine(engine);
    }
    final fx = declared(firmwareFile('fx.h')!);
    for (final n in heroFxParams) {
      expect(fx, contains(n));
    }
  }, skip: fw == null ? firmwareMissing : false);

  for (final engine in newerEngines) {
    final has = fw != null && firmwareFile(engineFiles[engine]!) != null;
    test('$engine: every hero name is a parameter in ${engineFiles[engine]}', () => checkEngine(engine),
        skip: fw == null
            ? firmwareMissing
            : has
            ? false
            : '${engineFiles[engine]} is not in the firmware at ${firmwarePath()} (${firmwareLayout()} layout): '
                  'set STRISO_FW_DIR to a checkout with the $engine engine');
  }

  test('every engine with hero knobs has its header named here', () {
    expect(engineFiles.keys.toSet(), containsAll(heroParams.keys));
    for (final voice in heroPresetParams.keys) {
      expect(heroParams.keys, contains(voice.split(':').first), reason: voice);
    }
  });

  test('picks the preset, then the engine, then the first continuous parameters', () {
    final list = [p('gain'), p('cut_base'), p('res'), p('cut_env'), p('drive'), p('b_sync', Kind.onOff), p('sub'), p('drift'), p('release')];
    expect(heroKnobs('va:classic', list).map((q) => q.name), ['cut_base', 'res', 'cut_env', 'drive', 'sub', 'release']);
    expect(heroKnobs('va:pad', list).map((q) => q.name).first, 'cut_base');
    expect(heroKnobs('va:pad', list).map((q) => q.name), contains('drift'));
    final other = [p('a'), p('b', Kind.onOff), p('c'), p('d'), p('e'), p('f'), p('g'), p('h'), p('i'), p('j')];
    expect(heroKnobs('strisy', other).map((q) => q.name), ['a', 'c', 'd', 'e', 'f', 'g', 'h', 'i']);
    expect(heroFx([p('chmix'), p('rvmix'), p('dlmix')]).map((q) => q.name), ['rvmix', 'dlmix']);
    expect(heroFx([p('rv_mix'), p('dl_mix')]).map((q) => q.name), ['rv_mix', 'dl_mix']);
  });

  test('trumpet: the mutes and the plunger lead with mute and wah', () {
    final list = [for (final n in ['gain', 'p_soft', 'p_loud', 'release', 'brassy', 'bell', 'attack', 'vibrato', 'lip_tune', 'breath', 'mute', 'wah', 'growl', 'fall', 'room']) p(n)];
    expect(heroKnobs('trumpet:bb classical', list).length, 8);
    for (final m in ['harmon', 'cup mute', 'straight', 'plunger']) {
      expect(heroKnobs('trumpet:$m', list).first.name, 'mute', reason: m);
    }
    expect(heroKnobs('trumpet:harmon', list).map((q) => q.name), contains('wah'));
    expect(heroKnobs('trumpet:plunger', list).map((q) => q.name).take(2), ['mute', 'wah']);
  });
}
