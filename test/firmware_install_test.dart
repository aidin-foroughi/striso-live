// Installing a firmware build for Virtual: a release zip checked against its manifest.json (the
// platform, the C API, the library's sha256), kept in the firmware folder; a library copied in;
// macOS's quarantine cleared on what is installed; and on Windows a clear word when the C++
// runtime the library needs is missing.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/firmware_library.dart';
import 'package:striso_virtual/striso_virtual.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fw_install'));
  tearDown(() => tmp.deleteSync(recursive: true));
  final lib = virtualLibName();
  final libBytes = utf8.encode('not really a library, but bytes with a hash');

  String zipOf({String platform = 'windows-x64', int api = svApiVersion, String? sha, bool manifest = true, String version = '2026-10-24 v2.3.0'}) {
    final top = 'striso_virtual-v2.3.0-$platform';
    final a = Archive();
    a.addFile(ArchiveFile.bytes('$top/$lib', libBytes));
    a.addFile(ArchiveFile.string('$top/striso_virtual.h', '/* header */'));
    if (manifest) {
      a.addFile(
        ArchiveFile.string(
          '$top/manifest.json',
          jsonEncode({
            'name': 'striso_virtual',
            'version': version,
            'platform': platform,
            'library': lib,
            'sha256': sha ?? sha256.convert(libBytes).toString(),
            'api_version': api,
            'firmware_version': '2026-10-24_v2.3.0_all',
          }),
        ),
      );
    }
    final f = File('${tmp.path}${Platform.pathSeparator}$top.zip')..writeAsBytesSync(ZipEncoder().encode(a));
    return f.path;
  }

  final calls = <List<String>>[];
  Future<ProcessResult> xattr(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    return ProcessResult(0, 0, '', '');
  }

  String fwDir() => '${tmp.path}${Platform.pathSeparator}firmware';

  test('a release zip: checked, unpacked as <folder>/<version>/, quarantine cleared', () async {
    calls.clear();
    final p = await installFirmware(zipOf(), fwDir(), apiVersion: svApiVersion, platform: 'windows-x64', run: xattr);
    expect(p, endsWith('${Platform.pathSeparator}2026-10-24 v2.3.0${Platform.pathSeparator}$lib'));
    expect(File(p).readAsBytesSync(), libBytes);
    expect(File('${File(p).parent.path}${Platform.pathSeparator}manifest.json').existsSync(), isTrue);
    expect(calls.single, ['xattr', '-dr', 'com.apple.quarantine', File(p).parent.path]);
    expect(findFirmwareBuilds(fwDir()).single.path, File(p).absolute.path, reason: 'the picker lists it');
    // installed again: replaced, not doubled
    await installFirmware(zipOf(), fwDir(), apiVersion: svApiVersion, platform: 'windows-x64', run: xattr);
    expect(findFirmwareBuilds(fwDir()).length, 1);
  });

  test('refused, with the reason: another platform, another C API, a wrong sha256, no manifest, not a zip', () async {
    Future<String> why(String zip, {String platform = 'windows-x64'}) async {
      try {
        await installFirmware(zip, fwDir(), apiVersion: svApiVersion, platform: platform, run: xattr);
        return 'installed';
      } on FirmwareInstallError catch (e) {
        return e.message;
      }
    }

    expect(await why(zipOf(platform: 'macos-universal')), contains('this computer needs windows-x64'));
    expect(await why(zipOf(api: svApiVersion + 1)), contains('use a firmware build for this app'));
    expect(await why(zipOf(sha: 'ab' * 32)), contains('does not match its manifest'));
    expect(await why(zipOf(manifest: false)), contains('no manifest.json'));
    final junk = File('${tmp.path}${Platform.pathSeparator}junk.zip')..writeAsStringSync('no zip');
    expect(await why(junk.path), contains('is not a zip'));
    expect(findFirmwareBuilds(fwDir()), isEmpty, reason: 'nothing half-installed');
  });

  test('a library file: copied into the firmware folder under its folder\'s name', () async {
    final d = Directory('${tmp.path}${Platform.pathSeparator}my build')..createSync();
    final f = File('${d.path}${Platform.pathSeparator}$lib')..writeAsBytesSync(libBytes);
    final p = await installFirmware(f.path, fwDir(), apiVersion: svApiVersion, run: xattr);
    expect(p, endsWith('my build${Platform.pathSeparator}$lib'));
    expect(p, isNot(f.absolute.path));
    expect(File(p).readAsBytesSync(), libBytes);
  });

  test('macOS: a quarantined download is installed without its quarantine (the real xattr)', () async {
    Future<bool> quarantined(String path) async => '${(await Process.run('xattr', ['-l', path])).stdout}'.contains('com.apple.quarantine');
    const mark = '0081;00000000;Safari;';
    // a library a browser downloaded: copied in, the copy cleared
    final d = Directory('${tmp.path}${Platform.pathSeparator}downloaded build')..createSync();
    final f = File('${d.path}${Platform.pathSeparator}$lib')..writeAsBytesSync(libBytes);
    expect((await Process.run('xattr', ['-w', 'com.apple.quarantine', mark, f.path])).exitCode, 0);
    expect(await quarantined(f.path), isTrue);
    final p = await installFirmware(f.path, fwDir(), apiVersion: svApiVersion);
    expect(await quarantined(p), isFalse, reason: 'installed without the quarantine');
    // a release zip from the browser: quarantined itself, what it unpacks is not
    final zip = zipOf(platform: 'macos-universal');
    expect((await Process.run('xattr', ['-w', 'com.apple.quarantine', mark, zip])).exitCode, 0);
    final q = await installFirmware(zip, fwDir(), apiVersion: svApiVersion, platform: 'macos-universal');
    expect(await quarantined(q), isFalse);
    expect(await quarantined(File(q).parent.path), isFalse);
  }, skip: Platform.isMacOS ? false : 'macOS only');

  test('Windows: a missing C++ runtime is said plainly (MSVCP140_ATOMIC_WAIT.dll is 14.28)', () {
    expect(StrisoVirtualLib.missingRuntime(windows: false), isNull);
    expect(StrisoVirtualLib.missingRuntime(windows: true, open: (_) {}), isNull);
    final why = StrisoVirtualLib.missingRuntime(
      windows: true,
      open: (n) {
        if (n == 'MSVCP140_ATOMIC_WAIT.dll') throw ArgumentError('error 126');
      },
    )!;
    expect(why, contains('Visual C++ Redistributable 2015-2022 (x64), 14.28 or later'));
    expect(why, contains('MSVCP140_ATOMIC_WAIT.dll is missing'));
    expect(why, contains('https://aka.ms/vs/17/release/vc_redist.x64.exe'));
    if (Platform.isWindows) expect(StrisoVirtualLib.missingRuntime(), isNull, reason: 'this PC has it');
  });
}
