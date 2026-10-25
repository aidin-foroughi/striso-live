// How a firmware build is named for the user (docs/flows.md 5 and 8): its manifest.json's title
// and description when the folder has one, else its folder's name; an unreadable manifest names
// nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/controller.dart' show commitOf;
import 'package:striso_live/src/firmware_library.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fw_builds'));
  tearDown(() => tmp.deleteSync(recursive: true));
  final sep = Platform.pathSeparator;

  String folder(String name, {Map<String, Object?>? manifest, String? rawManifest}) {
    final d = Directory('${tmp.path}$sep$name')..createSync();
    File('${d.path}$sep${virtualLibName()}').writeAsStringSync('bytes');
    if (manifest != null) File('${d.path}${sep}manifest.json').writeAsStringSync(jsonEncode(manifest));
    if (rawManifest != null) File('${d.path}${sep}manifest.json').writeAsStringSync(rawManifest);
    return '${d.path}$sep${virtualLibName()}';
  }

  final base = {
    'name': 'striso_virtual',
    'version': '2026-10-24_audition sax v1 (56f7266)',
    'platform': 'windows-x64',
    'library': 'striso_virtual.dll',
    'sha256': 'ab',
    'api_version': 2,
    'firmware_version': '2026-10-25_v2.2.4-299-g56f7266_all',
  };

  test('the manifest carries a title and a description; blank ones count as none', () {
    final m = FirmwareManifest.parse(jsonEncode({...base, 'title': ' Sax v1 ', 'description': 'Four saxes on the wind key.'}));
    expect(m.title, 'Sax v1');
    expect(m.description, 'Four saxes on the wind key.');
    final none = FirmwareManifest.parse(jsonEncode({...base, 'title': '  ', 'description': 7}));
    expect(none.title, isNull);
    expect(none.description, isNull);
  });

  test('a build is titled by its manifest, else by its folder; a broken manifest names nothing', () {
    final sax = buildOf(folder('2026-10-24_audition sax v1 (56f7266)', manifest: {...base, 'title': 'Sax v1', 'description': 'Four saxes.'}));
    expect(sax.title, 'Sax v1');
    expect(sax.description, 'Four saxes.');
    expect(sax.name, '2026-10-24_audition sax v1 (56f7266)');
    final bare = buildOf(folder('2026-10-25_v2.2.4-308-g3e05282_all'));
    expect(bare.title, '2026-10-25_v2.2.4-308-g3e05282_all');
    expect(bare.description, isNull);
    final broken = buildOf(folder('odd', rawManifest: '{not json'));
    expect(broken.title, 'odd');
    expect(broken.manifest, isNull);
    final untitled = buildOf(folder('plain', manifest: base));
    expect(untitled.title, 'plain', reason: 'a manifest without a title names nothing');
    expect(untitled.manifest, isNotNull);
  });

  test('the folder is listed newest name first, each with its manifest', () {
    folder('2026-10-24_audition sax v1 (56f7266)', manifest: {...base, 'title': 'Sax v1'});
    folder('2026-10-25_v2.2.4-308-g3e05282_all');
    Directory('${tmp.path}${sep}empty').createSync(); // no library: not a build
    final list = findFirmwareBuilds(tmp.path);
    expect(list.map((b) => b.title), ['2026-10-25_v2.2.4-308-g3e05282_all', 'Sax v1']);
  });

  test('the commit of a firmware version, as the board or a library reports it', () {
    expect(commitOf('2026-10-25_v2.2.4-308-g3e05282_all'), '3e05282');
    expect(commitOf('strisoboard_v2.2.4-308-g3e05282'), '3e05282');
    expect(commitOf('v2.2.4'), isNull);
    expect(commitOf(null), isNull);
  });
}
