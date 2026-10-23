// The hero knob names against the firmware's parameter tables, and the fallbacks.
import 'dart:io';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

Directory? firmwareDir() {
  for (var d = Directory.current; d.parent.path != d.path; d = d.parent) {
    final f = Directory('${d.path}/striso-control-firmware');
    if (File('${f.path}/fx.h').existsSync()) return f;
  }
  return null;
}

/// Parameter names declared in a firmware header: {"name", "group", min, max, kind}.
Set<String> declared(File f) => {for (final m in RegExp(r'\{\s*"([a-z0-9_]+)",\s*"([a-z_]+)",').allMatches(f.readAsStringSync())) m[1]!};

Param p(String name, [int kind = 0]) => Param(index: 0, name: name, group: 'g', min: 0, max: 1, value: 0.5, kind: kind);

void main() {
  final fw = firmwareDir();
  test('every hero name is a parameter of its engine in the firmware', () {
    const files = {'va': 'voice_va.h', 'bowed': 'voice_bowed.h', 'modal': 'voice_modal.h', 'wind': 'voice_wind.h', 'brass': 'voice_brass.h', 'ep': 'voice_ep.h'};
    for (final MapEntry(key: engine, value: names) in heroParams.entries) {
      final have = declared(File('${fw!.path}/${files[engine]}'));
      for (final n in names) {
        expect(have, contains(n), reason: '$engine: $n');
      }
    }
    for (final MapEntry(key: voice, value: names) in heroPresetParams.entries) {
      final have = declared(File('${fw!.path}/${files[voice.split(':').first]}'));
      for (final n in names) {
        expect(have, contains(n), reason: '$voice: $n');
      }
    }
    final fx = declared(File('${fw!.path}/fx.h'));
    for (final n in heroFxParams) {
      expect(fx, contains(n));
    }
  }, skip: fw == null ? 'firmware source not found' : false);

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
}
