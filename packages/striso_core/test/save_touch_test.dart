// Save to Striso's half on the computer: the firmware's config (Stcc, recorded from the virtual
// board in test/fixtures/config_uf2.txt) read from its reply, the guard on what may be written, and
// the copy to the one Striso update drive after a backup. The config itself is the firmware's: the
// app builds none. No board is involved.
import 'dart:io';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

Matcher refuses(String what) => throwsA(isA<ConfigError>().having((e) => e.message, 'message', contains(what)));

void main() {
  final reply = readFixture('config_uf2.txt')['c'];

  test('the firmware\'s Stcc reply: its bytes, whole UF2 blocks of the config area', () {
    final data = parseConfigReply(reply);
    expect(data.length, int.parse(reply.first.split(' ').last));
    expect(data.length % 512, 0);
    checkConfigUf2(data);
    // the records are the firmware's: its header record and the save's preset
    expect(String.fromCharCodes(data.sublist(32, 48)), 'MConfig v1.0    ');
    expect(String.fromCharCodes(data), contains('iGpreset1       '));
  });

  test('a reply that is not whole, not hex or the board\'s refusal: no bytes', () {
    expect(() => parseConfigReply(reply.sublist(0, reply.length - 1)), refuses('whole'));
    expect(() => parseConfigReply([reply.first, ...reply.sublist(2)]), refuses('whole'));
    expect(() => parseConfigReply([reply.first, 'zz', 'c end']), refuses('not hex'));
    expect(() => parseConfigReply(['c err too large: 9000 records']), refuses('too large: 9000 records'));
    expect(() => parseConfigReply(const []), refuses('whole'));
  });

  test('the guard: only Striso config blocks inside 0x08020000..0x08040000', () {
    final data = parseConfigReply(reply);
    expect(() => checkConfigUf2(Uint8List(0)), refuses('not a UF2'));
    expect(() => checkConfigUf2(Uint8List(100)), refuses('not a UF2'));
    final outside = Uint8List.fromList(data);
    ByteData.sublistView(outside).setUint32(12, 0x08000000, Endian.little);
    expect(() => checkConfigUf2(outside), refuses('outside the config area'));
    final foreign = Uint8List.fromList(data);
    ByteData.sublistView(foreign).setUint32(28, 0x12345678, Endian.little);
    expect(() => checkConfigUf2(foreign), refuses('not a Striso UF2 block'));
  });

  group('save to a drive', () {
    late Directory tmp;
    late Uint8List config;
    final previous = Uint8List.fromList(List.generate(512, (i) => i & 0xff));
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('striso_save');
      config = parseConfigReply(reply);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory drive(String name, String info) {
      final d = Directory('${tmp.path}${Platform.pathSeparator}$name')..createSync();
      File('${d.path}/INFO_UF2.TXT').writeAsStringSync(info);
      File('${d.path}/CONFIG.UF2').writeAsBytesSync(previous);
      return d;
    }

    List<String> roots() => tmp.listSync().whereType<Directory>().map((d) => d.path).toList();

    test('writes the firmware\'s config as NEWCFG.UF2 to the one Striso drive after a backup, waits for the restart', () async {
      final striso = drive('S', 'UF2 Bootloader v1.0\r\nModel: Striso control board\r\n');
      drive('X', 'UF2 Bootloader\r\nModel: some other board\r\n');
      final steps = <String>[];
      final save = saveTouch(config, backupDir: '${tmp.path}/backups', progress: steps.add, roots: roots, rebootTimeout: const Duration(seconds: 10));
      // the board reboots once the file is written: the drive goes away
      while (!File('${striso.path}/NEWCFG.UF2').existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final written = File('${striso.path}/NEWCFG.UF2').readAsBytesSync();
      File('${striso.path}/INFO_UF2.TXT').deleteSync();
      final r = await save;
      expect(r.ok, isTrue, reason: r.message);
      expect(written, config, reason: 'the bytes as the firmware built them');
      expect(File(r.backupPath!).readAsBytesSync(), previous);
      expect(File('${tmp.path}/X/NEWCFG.UF2').existsSync(), isFalse, reason: 'the other drive is not touched');
      expect(steps.first, contains('update drive'));
    });

    test('two Striso drives: refuses and writes nothing', () async {
      drive('A', 'Model: Striso');
      drive('B', 'Model: Striso');
      final r = await saveTouch(config, backupDir: '${tmp.path}/backups', roots: roots);
      expect(r.ok, isFalse);
      expect(r.message, contains('more than one'));
      expect(File('${tmp.path}/A/NEWCFG.UF2').existsSync() || File('${tmp.path}/B/NEWCFG.UF2').existsSync(), isFalse);
    });

    test('no drive: times out, nothing written; a config outside the area: refused before anything', () async {
      final r = await saveTouch(config, backupDir: '${tmp.path}/backups', roots: roots, driveTimeout: const Duration(milliseconds: 300));
      expect(r.ok, isFalse);
      expect(r.message, contains('timed out'));
      drive('S', 'Model: Striso');
      final bad = Uint8List.fromList(config);
      ByteData.sublistView(bad).setUint32(12, 0x08000000, Endian.little);
      final refused = await saveTouch(bad, backupDir: '${tmp.path}/backups', roots: roots);
      expect(refused.ok, isFalse);
      expect(refused.message, contains('outside the config area'));
      expect(File('${tmp.path}/S/NEWCFG.UF2').existsSync(), isFalse);
      expect(Directory('${tmp.path}/backups').existsSync(), isFalse, reason: 'refused before the backup');
    });

    test('--fake-save: every step but the drive; fail says so', () async {
      final ok = await saveTouch(config, backupDir: '${tmp.path}/backups', fake: 'ok', roots: () => throw StateError('no drive is looked for'));
      expect(ok.ok, isTrue, reason: ok.message);
      final fail = await saveTouch(config, backupDir: '${tmp.path}/backups', fake: 'fail', roots: () => throw StateError('no drive is looked for'));
      expect(fail.ok, isFalse);
      expect(fail.message, contains('fake save failure'));
    });
  });
}
