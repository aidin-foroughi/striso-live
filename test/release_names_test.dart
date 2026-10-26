// The release's file names, the same everywhere: what the packaging scripts write, what
// .github/workflows/release.yml checks, uploads and sums, what the one-line installers download
// (the fixed names and their .sha256) and what the README names. A rename in one place fails here,
// not in a user's install. Also: a tag is checked against pubspec.yaml's version in both release
// jobs, and the version has its section in CHANGELOG.md (the release's notes).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final version = RegExp(r'^version: *([0-9][0-9.]*)', multiLine: true).firstMatch(read('pubspec.yaml'))![1]!;
  final workflow = read('.github/workflows/release.yml');
  final readme = read('README.md');
  final changelog = read('CHANGELOG.md');

  // the four versioned assets and the two fixed names the installers fetch
  const winZip = r'StrisoLive-$v-windows-x64.zip', winSetup = r'StrisoLive-$v-windows-setup.exe';
  const macZip = r'StrisoLive-$v-macos.zip', macDmg = r'StrisoLive-$v-macos.dmg';
  const fixedWin = 'StrisoLive-windows-x64.zip', fixedMac = 'StrisoLive-macos.zip';

  test('the packaging scripts write the names the release workflow checks', () {
    expect(read('tool/package_windows.ps1'), contains(r'dist\StrisoLive-$version-windows-x64.zip'));
    expect(read('tool/installer.iss'), contains('OutputBaseFilename=StrisoLive-{#AppVersion}-windows-setup'));
    expect(read('tool/installer.iss'), contains(r'OutputDir=..\dist'));
    final mac = read('tool/package_macos.sh');
    expect(mac, contains(r'zip="dist/StrisoLive-$version-macos.zip"'));
    expect(mac, contains(r'dmg="dist/StrisoLive-$version-macos.dmg"'));
    for (final name in [winZip, winSetup, macZip, macDmg]) {
      expect(workflow, contains(name), reason: 'release.yml checks and uploads $name');
    }
  });

  test('the fixed names the installers download are made, summed and uploaded by the release', () {
    expect(read('install-windows.ps1'), contains("\$asset = '$fixedWin'"));
    expect(read('install-windows.ps1'), contains(r'$sumUrl = "$zipUrl.sha256"'));
    expect(read('install-mac.sh'), contains('local asset="$fixedMac"'));
    expect(read('install-mac.sh'), contains(r'local sum_url="$base/$asset.sha256"'));
    expect(workflow, contains('cp "dist/$winZip" dist/$fixedWin'));
    expect(workflow, contains('cp "dist/$macZip" dist/$fixedMac'));
    expect(workflow, contains('for f in $fixedWin $fixedMac; do sha256sum "\$f" > "\$f.sha256"; done'));
    expect(workflow, contains('SHA256SUMS.txt'));
    // both installers fetch from the latest release by default (the fixed names make that a stable link)
    expect(read('install-windows.ps1'), contains('releases/latest/download'));
    expect(read('install-mac.sh'), contains('releases/latest/download'));
  });

  test('the README names the same files', () {
    for (final name in [winZip, winSetup, macZip, macDmg]) {
      expect(readme, contains(name.replaceAll(r'$v', '<version>')), reason: name);
    }
    expect(readme, contains('`$fixedMac`'));
    expect(readme, contains('`$fixedWin`'));
    expect(readme, contains('SHA256SUMS.txt'));
  });

  test('a tag must match pubspec.yaml in both release jobs; the version has its notes', () {
    expect(RegExp(r'does not match pubspec\.yaml version').allMatches(workflow).length, 2, reason: 'the Windows and the macOS job');
    expect(workflow, contains(r'"$GITHUB_REF_NAME" != "v$v"'));
    expect(changelog, contains('\n## $version\n'), reason: 'CHANGELOG.md has a section for $version: the release notes');
    // the notes step reads the section by the version (## <version>)
    expect(workflow, contains(r'''awk -v v="$VERSION" '/^## /{p = ($2 == v); next} p' src/CHANGELOG.md'''));
  });
}
