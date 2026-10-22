// The config writer against tools/striso.py: the same bytes for the same inputs, round trips and
// refusals; the save flow against fake drives. No board is involved.
// Port of tools/app/test/desktop-config.test.mjs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

const touchNames = ['pressure', 'velocity', 'tilt', 'bend', 'threshold'];
const _notes = ['C_', 'Db', 'C#', 'D_', 'Eb', 'D#', 'E_', 'F_', 'Gb', 'F#', 'G_', 'Ab', 'G#', 'A_', 'Bb', 'A#', 'B_'];
final keyNames = [for (var n = 0; n < 61; n++) '${_notes[(n + 7) % 17]}${1 + (n + 7) ~/ 17}'];
const _range = {'pressure': (0.1, 4.0), 'velocity': (0.1, 4.0), 'tilt': (-4.0, 4.0), 'bend': (0.0, 8.0), 'threshold': (0.0, 0.5)};

double Function() rng(int seed) {
  var s = seed & 0xffffffff;
  if (s == 0) s = 1;
  return () {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return s / 4294967296;
  };
}

class Case {
  final Uint8List current;
  final TouchValues values;
  Case(this.current, this.values);
}

Case randomCase(double Function() r) {
  T pick<T>(List<T> a) => a[(r() * a.length).floor()];
  final recs = <Record>[];
  final n = (r() * 30).floor();
  final pool = ['iGoct   ', 'iGpreset', 'fP1presS', 'hP0color', 'sP1name ', 'fCfacC_2', 'fCfacF_1', 'iMint   ', 'fP2veloS', for (final k in keyNames.take(8)) 'fCfac$k'];
  for (var k = 0; k < n; k++) {
    final key = pick(pool);
    final val = pick(['1', '0', '0.5', '-2', '00aa00', 'Pad', '1.2345', '3', '        ', 'x']).padRight(8);
    recs.add((key.padRight(8).substring(0, 8), val));
  }
  const ties = [0.03125, 1.03125, 0.15625, 2.00005, 0.99995, 1.00004, 1.0, 1.00011, 0.1, 10.0, 4.0, 0.5, 0.00005];
  final touch = [
    for (final name in touchNames)
      (name, toFloat32(() {
        final (lo, hi) = _range[name]!;
        return r() < 0.3 ? pick(ties.where((x) => x >= lo && x <= hi).toList()) : lo + r() * (hi - lo);
      }())),
  ];
  final keys = [
    for (final name in keyNames)
      (name, toFloat32(r() < 0.5 ? 1 : (r() < 0.2 ? pick(ties.where((x) => x >= 0.1 && x <= 10).toList()) : 0.6 + r()))),
  ];
  return Case(configUf2(recs), TouchValues(touch, keys));
}

String? findPython() {
  for (var d = Directory.current; d.parent.path != d.path; d = d.parent) {
    for (final p in ['${d.path}/tools/.venv/Scripts/python.exe', '${d.path}/tools/.venv/bin/python', '${d.path}/.venv/Scripts/python.exe']) {
      if (File(p).existsSync() && File('${File(p).parent.parent.parent.path}/app/test/fixtures/config_ref.py').existsSync()) return p;
    }
  }
  return null;
}

void main() {
  test('fmt8 follows Python formatting, including half-to-even ties and signs', () {
    final want = <double, String>{
      1.0: '1', 1.5: '1.5', 0.1: '0.1', 2.3: '2.3', 10.0: '10', 0.0: '0', -1.5: '-1.5', 0.03125: '0.0312', 0.15625: '0.1562',
      1.03125: '1.0312', 0.09375: '0.0938', 123456.789: '123456.7', -0.00001: '-0', 0.99996: '1',
    };
    want.forEach((v, s) => expect(fmt8(v), s, reason: '$v'));
    expect(fmt8(double.nan), '1');
    expect(fmt8(toFloat32(1.1)), '1.1');
  });

  test('config round trip and the touch update list', () {
    const recs = [('iGoct   ', '1       '), ('fCfacC_2', '1.07    '), ('hP0color', '00aa00  ')];
    final uf2 = configUf2(recs);
    expect(configParse(uf2), recs);
    expect(uf2.length, 512);
    expect(ByteData.sublistView(uf2).getUint32(12, Endian.little), 0x08020000);
    final c = randomCase(rng(1));
    final values = TouchValues(c.values.touch, [for (final (n, (name, _)) in c.values.keys.indexed) (name, n == 7 ? toFloat32(1.25) : 1.0)]);
    final u = touchUpdates(values);
    expect(u.updates.sublist(0, 2), [('iGpreset', '1'), ('fP1presS', fmt8(values.touch[0].$2))]);
    expect(u.updates[6], ('fCfac${keyNames[7]}', '1.25'));
    expect(keyNames[7], 'Bb1');
    expect(u.remove.length, 60);
    final merged = buildConfig(uf2, values).recs;
    expect(merged.any((r) => r.$1 == 'fCfacC_2'), isFalse, reason: 'factors back at 1.0 are removed');
    expect(merged.any((r) => r.$1 == 'iGoct   ' && r.$2 == '1       '), isTrue, reason: 'other settings are kept');
    expect(configParse(Uint8List(0)), isEmpty);
  });

  test('refusals: too large, outside the config area, bad bytes, unexpected values', () {
    final many = [for (var k = 0; k < 8200; k++) ('k${'$k'.padLeft(7, '0')}', '1')];
    Matcher refuses(String text) => throwsA(isA<ConfigError>().having((e) => e.message, 'message', contains(text)));
    expect(() => configUf2(many), refuses('leave the config area'));
    expect(() => configUf2([('toolongkey', '1')]), refuses('too long'));
    expect(() => configUf2([('kŁ', '1')]), refuses('not ASCII'));
    final bad = Uint8List.fromList(configUf2([('iGoct   ', '1       ')]));
    bad[32 + 16 + 8] = 0xe9;
    expect(() => configParse(bad), refuses('non-ASCII'));
    final outside = Uint8List.fromList(configUf2([('iGoct   ', '1')]));
    ByteData.sublistView(outside).setUint32(12, 0x08000000, Endian.little);
    expect(() => checkUf2Range(outside), refuses('outside the config area'));
    final foreign = Uint8List.fromList(configUf2([('iGoct   ', '1')]));
    ByteData.sublistView(foreign).setUint32(28, 0x12345678, Endian.little);
    expect(() => checkUf2Range(foreign), refuses('not a Striso UF2 block'));
    final v = randomCase(rng(2)).values;
    expect(() => touchUpdates(TouchValues(v.touch.sublist(1), v.keys)), refuses('no live touch'));
    expect(() => touchUpdates(TouchValues(v.touch, [...v.keys.sublist(1), ('Hx9', 1.0)])), refuses('unexpected key name'));
    final hot = [...v.keys];
    hot[3] = (hot[3].$1, 12.0);
    expect(() => touchUpdates(TouchValues(v.touch, hot)), refuses('out of range'));
    final dup = [...v.touch];
    dup[1] = ('pressure', dup[1].$2);
    expect(() => touchUpdates(TouchValues(dup, v.keys)), refuses('unexpected touch'));
  });

  final python = findPython();
  test('byte-identical to tools/striso.py on 150 random saves', () async {
    final py = python!;
    final fixture = '${File(py).parent.parent.parent.path}/app/test/fixtures/config_ref.py';
    final r = rng(77);
    final cases = [for (var k = 0; k < 150; k++) randomCase(r)];
    final fmtCases = [0.03125, 1.03125, 0.15625, 2.00005, -0.00001, 0.99996, 1e-5, 7.99999, 3.14159265, -3.99995, toFloat32(0.3), toFloat32(1.7)];
    final input = [
      for (final c in cases)
        {
          'current': base64Encode(c.current),
          'touch': [for (final (n, v) in c.values.touch) [n, v]],
          'keys': [for (final (n, v) in c.values.keys) [n, v]],
        },
      for (final v in fmtCases) {'fmt8': v},
    ];
    final p = await Process.start(py, ['-I', fixture]);
    final stdout = p.stdout.transform(utf8.decoder).join(), stderr = p.stderr.transform(utf8.decoder).join();
    p.stdin.write(jsonEncode(input));
    await p.stdin.close();
    expect(await p.exitCode, 0, reason: await stderr);
    final out = jsonDecode(await stdout) as List;
    for (var k = 0; k < cases.length; k++) {
      expect(base64Encode(buildConfig(cases[k].current, cases[k].values).data), out[k], reason: 'case $k');
    }
    for (var k = 0; k < fmtCases.length; k++) {
      expect(fmt8(fmtCases[k]), out[cases.length + k], reason: 'fmt8(${fmtCases[k]})');
    }
  }, skip: python == null ? 'tools/.venv not found' : false);

  group('save to a drive', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('striso_save'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory drive(String name, String info, [Uint8List? config]) {
      final d = Directory('${tmp.path}${Platform.pathSeparator}$name')..createSync();
      File('${d.path}/INFO_UF2.TXT').writeAsStringSync(info);
      File('${d.path}/CONFIG.UF2').writeAsBytesSync(config ?? configUf2([('iGoct   ', '1       ')]));
      return d;
    }

    final values = randomCase(rng(3)).values;

    test('writes NEWCFG.UF2 to the one Striso drive after a backup, waits for the restart', () async {
      final striso = drive('S', 'UF2 Bootloader v1.0\r\nModel: Striso control board\r\n');
      drive('X', 'UF2 Bootloader\r\nModel: some other board\r\n');
      final steps = <String>[];
      final save = saveTouch(values,
          backupDir: '${tmp.path}/backups', progress: steps.add, roots: () => tmp.listSync().whereType<Directory>().map((d) => d.path).toList(),
          rebootTimeout: const Duration(seconds: 10));
      // the board reboots once the file is written: the drive goes away
      while (!File('${striso.path}/NEWCFG.UF2').existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final written = File('${striso.path}/NEWCFG.UF2').readAsBytesSync();
      File('${striso.path}/INFO_UF2.TXT').deleteSync();
      final r = await save;
      expect(r.ok, isTrue, reason: r.message);
      expect(written, buildConfig(configUf2([('iGoct   ', '1       ')]), values).data);
      checkUf2Range(written);
      expect(File(r.backupPath!).readAsBytesSync(), configUf2([('iGoct   ', '1       ')]));
      expect(File('${tmp.path}/X/NEWCFG.UF2').existsSync(), isFalse, reason: 'the other drive is not touched');
      expect(steps.first, contains('update drive'));
    });

    test('two Striso drives: refuses and writes nothing', () async {
      drive('A', 'Model: Striso');
      drive('B', 'Model: Striso');
      final r = await saveTouch(values, backupDir: '${tmp.path}/backups', roots: () => [for (final n in ['A', 'B']) '${tmp.path}/$n']);
      expect(r.ok, isFalse);
      expect(r.message, contains('more than one'));
      expect(File('${tmp.path}/A/NEWCFG.UF2').existsSync() || File('${tmp.path}/B/NEWCFG.UF2').existsSync(), isFalse);
    });

    test('bad values: refused before any drive is looked at', () async {
      var looked = false;
      final bad = TouchValues(values.touch, [...values.keys.sublist(1), ('Q_1', 1.0)]);
      final r = await saveTouch(bad, backupDir: '${tmp.path}/backups', roots: () {
        looked = true;
        return const [];
      });
      expect(r.ok, isFalse);
      expect(looked, isFalse);
    });

    test('fake save: ok and fail, no drive touched', () async {
      final ok = await saveTouch(values, backupDir: '${tmp.path}/backups', fake: 'ok');
      expect(ok.ok, isTrue);
      final fail = await saveTouch(values, backupDir: '${tmp.path}/backups', fake: 'fail');
      expect(fail.ok, isFalse);
      expect(fail.message, contains('fake'));
    });

    test('no drive: times out', () async {
      final r = await saveTouch(values, backupDir: '${tmp.path}/backups', roots: () => const [], driveTimeout: const Duration(milliseconds: 600));
      expect(r.ok, isFalse);
      expect(r.message, contains('timed out'));
    });
  });
}
