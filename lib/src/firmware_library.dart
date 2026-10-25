// The virtual Striso's firmware builds on this computer (the app ships none): every folder in
// <app data>/firmware/ that holds a striso_virtual library, e.g.
//   %APPDATA%\Striso Live\firmware\2026-10-24 v2.2.4-80\striso_virtual.dll
//   ~/Library/Application Support/Striso Live/firmware/2026-10-24 v2.2.4-80/libstriso_virtual.dylib
// A firmware release publishes the library next to its UF2 (striso_virtual-<version>-*.zip).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// The library's file name on this system.
String virtualLibName() => Platform.isWindows ? 'striso_virtual.dll' : (Platform.isMacOS ? 'libstriso_virtual.dylib' : 'libstriso_virtual.so');

class FirmwareBuild {
  /// The library file.
  final String path;

  /// Its folder's name (the version it was published as), or the file's folder for one loaded
  /// from elsewhere.
  final String name;

  /// What its manifest.json says about it, when the folder has one (a release zip installed by
  /// the app; an audition that was given one).
  final FirmwareManifest? manifest;
  const FirmwareBuild(this.path, this.name, {this.manifest});

  /// How the user knows it: the manifest's title, else the folder's name.
  String get title => manifest?.title ?? name;
  String? get description => manifest?.description;
  @override
  bool operator ==(Object other) => other is FirmwareBuild && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// The builds in [dir] (one per folder), newest name first.
List<FirmwareBuild> findFirmwareBuilds(String? dir) {
  if (dir == null) return const [];
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <FirmwareBuild>[];
  try {
    for (final e in d.listSync()) {
      if (e is! Directory) continue;
      final f = File('${e.path}${Platform.pathSeparator}${virtualLibName()}');
      if (f.existsSync()) out.add(buildOf(f.absolute.path));
    }
  } catch (_) {}
  out.sort((a, b) => b.name.compareTo(a.name));
  return out;
}

/// A library file anywhere, as a build: its folder's name, and its manifest.json when the folder
/// has a readable one.
FirmwareBuild buildOf(String path) {
  final abs = File(path).absolute.path;
  final parts = abs.split(RegExp(r'[\\/]'));
  final name = parts.length > 1 ? parts[parts.length - 2] : parts.last;
  FirmwareManifest? m;
  final mf = File('${File(abs).parent.path}${Platform.pathSeparator}manifest.json');
  if (mf.existsSync()) {
    try {
      m = FirmwareManifest.parse(mf.readAsStringSync());
    } catch (_) {
      m = null; // a manifest the app cannot read names nothing; the folder's name does
    }
  }
  return FirmwareBuild(abs, name, manifest: m);
}

/// The release's platform word for this system (in striso_virtual-VERSION-PLATFORM.zip).
String virtualPlatform() => Platform.isWindows ? 'windows-x64' : (Platform.isMacOS ? 'macos-universal' : 'linux-x64');

class FirmwareInstallError implements Exception {
  final String message;
  const FirmwareInstallError(this.message);
  @override
  String toString() => message;
}

/// What a build says about itself (manifest.json, the firmware's tools/package.sh; an audition's
/// folder gets one too). `title` and `description` are how the user knows the build
/// (docs/flows.md 8); the rest checks the zip at install time.
class FirmwareManifest {
  final String version, platform, library, sha256;
  final int apiVersion;
  final String? firmwareVersion, runtime, title, description;
  const FirmwareManifest({
    required this.version,
    required this.platform,
    required this.library,
    required this.sha256,
    required this.apiVersion,
    this.firmwareVersion,
    this.runtime,
    this.title,
    this.description,
  });

  static FirmwareManifest parse(String json) {
    final Object? j;
    try {
      j = jsonDecode(json);
    } catch (e) {
      throw FirmwareInstallError('its manifest.json is not JSON: $e');
    }
    if (j is! Map) throw const FirmwareInstallError('its manifest.json is not an object');
    final Map<Object?, Object?> m = j;
    String str(String k) {
      final v = m[k];
      if (v is! String || v.isEmpty) throw FirmwareInstallError('its manifest.json has no "$k"');
      return v;
    }

    final api = m['api_version'];
    if (api is! int) throw const FirmwareInstallError('its manifest.json has no "api_version"');
    return FirmwareManifest(
      version: str('version'),
      platform: str('platform'),
      library: str('library'),
      sha256: str('sha256').toLowerCase(),
      apiVersion: api,
      firmwareVersion: m['firmware_version'] is String ? m['firmware_version'] as String : null,
      runtime: m['runtime'] is String ? m['runtime'] as String : null,
      title: m['title'] is String && (m['title'] as String).trim().isNotEmpty ? (m['title'] as String).trim() : null,
      description: m['description'] is String && (m['description'] as String).trim().isNotEmpty ? (m['description'] as String).trim() : null,
    );
  }
}

/// A folder name from a version: no path separators or characters Windows refuses.
String safeFolder(String v) => v.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();

/// macOS: a file downloaded by a browser (and what is unpacked from it by the system) carries the
/// quarantine attribute, and dlopen refuses an unsigned quarantined library. The app clears it on
/// what it installs. Elsewhere nothing to do. Returns false when xattr failed.
Future<bool> clearQuarantine(String path, {Future<ProcessResult> Function(String, List<String>)? run}) async {
  if (!Platform.isMacOS && run == null) return true;
  final r = await (run ?? Process.run)('xattr', ['-dr', 'com.apple.quarantine', path]);
  // exit 1 with "No such xattr" is fine: nothing was quarantined
  return r.exitCode == 0 || '${r.stderr}'.contains('No such xattr');
}

/// Installs a firmware build into [firmwareDir] and returns its library's path:
/// - a release zip (striso_virtual-VERSION-PLATFORM.zip): unpacked, its manifest.json checked
///   (this platform, the C API [apiVersion], the library's sha256), kept as DIR/VERSION/;
/// - a library file: copied into DIR/its folder's name/.
/// macOS: the quarantine attribute is cleared on what is installed.
Future<String> installFirmware(
  String source,
  String firmwareDir, {
  required int apiVersion,
  String? platform,
  Future<ProcessResult> Function(String, List<String>)? run,
}) async {
  final src = File(source);
  if (!src.existsSync()) throw FirmwareInstallError('$source is not there');
  final dir = Directory(firmwareDir)..createSync(recursive: true);
  final sep = Platform.pathSeparator;
  final String dest, lib;
  if (source.toLowerCase().endsWith('.zip')) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(src.readAsBytesSync());
    } catch (e) {
      throw FirmwareInstallError('${src.uri.pathSegments.last} is not a zip: $e');
    }
    if (zip.isEmpty) throw FirmwareInstallError('${src.uri.pathSegments.last} is not a zip (or it is empty)');
    final mf = zip.files.where((f) => f.isFile && (f.name == 'manifest.json' || f.name.endsWith('/manifest.json'))).toList();
    if (mf.length != 1) throw const FirmwareInstallError('it is not a striso_virtual release (no manifest.json)');
    final top = mf.single.name.substring(0, mf.single.name.length - 'manifest.json'.length);
    final m = FirmwareManifest.parse(utf8.decode(mf.single.content as List<int>));
    final want = platform ?? virtualPlatform();
    if (m.platform != want) throw FirmwareInstallError('it is the build for ${m.platform}; this computer needs $want');
    if (m.apiVersion != apiVersion) {
      throw FirmwareInstallError('its C API is version ${m.apiVersion}, this app speaks version $apiVersion: use a firmware build for this app');
    }
    final libEntry = zip.files.where((f) => f.isFile && f.name == '$top${m.library}').firstOrNull;
    if (libEntry == null) throw FirmwareInstallError('the zip has no ${m.library}');
    final bytes = libEntry.content as List<int>;
    final got = sha256.convert(bytes).toString();
    if (got != m.sha256) throw FirmwareInstallError('${m.library} does not match its manifest (sha256 $got, the manifest says ${m.sha256})');
    dest = '${dir.path}$sep${safeFolder(m.version)}';
    final tmp = Directory('$dest.incoming');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    for (final f in zip.files) {
      if (!f.isFile || !f.name.startsWith(top)) continue;
      final rel = f.name.substring(top.length);
      if (rel.isEmpty || rel.contains('..')) continue;
      final out = File('${tmp.path}$sep${rel.replaceAll('/', sep)}');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(f.content as List<int>, flush: true);
    }
    final old = Directory(dest);
    if (old.existsSync()) old.deleteSync(recursive: true);
    tmp.renameSync(dest);
    lib = '$dest$sep${m.library}';
  } else {
    if (!source.endsWith(virtualLibName())) throw FirmwareInstallError('pick a release zip or a ${virtualLibName()}');
    final parts = src.absolute.path.split(RegExp(r'[\\/]'));
    dest = '${dir.path}$sep${safeFolder(parts.length > 1 ? parts[parts.length - 2] : 'loaded')}';
    Directory(dest).createSync(recursive: true);
    lib = '$dest$sep${virtualLibName()}';
    if (File(lib).absolute.path != src.absolute.path) src.copySync(lib);
  }
  if (!await clearQuarantine(dest, run: run)) throw FirmwareInstallError('macOS keeps it in quarantine (xattr failed on $dest)');
  return File(lib).absolute.path;
}
