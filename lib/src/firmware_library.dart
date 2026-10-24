// The virtual Striso's firmware builds on this computer (the app ships none): every folder in
// <app data>/firmware/ that holds a striso_virtual library, e.g.
//   %APPDATA%\Striso Live\firmware\2026-10-24 v2.2.4-80\striso_virtual.dll
//   ~/Library/Application Support/Striso Live/firmware/2026-10-24 v2.2.4-80/libstriso_virtual.dylib
// A firmware release publishes the library next to its UF2 (striso_virtual-<version>-*.zip).

import 'dart:io';

/// The library's file name on this system.
String virtualLibName() => Platform.isWindows ? 'striso_virtual.dll' : (Platform.isMacOS ? 'libstriso_virtual.dylib' : 'libstriso_virtual.so');

class FirmwareBuild {
  /// The library file.
  final String path;

  /// Its folder's name (the version it was published as), or the file's folder for one loaded
  /// from elsewhere.
  final String name;
  const FirmwareBuild(this.path, this.name);
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
      if (f.existsSync()) out.add(FirmwareBuild(f.absolute.path, e.path.split(RegExp(r'[\/]')).last));
    }
  } catch (_) {}
  out.sort((a, b) => b.name.compareTo(a.name));
  return out;
}

/// A library file anywhere, as a build.
FirmwareBuild buildOf(String path) {
  final parts = File(path).absolute.path.split(RegExp(r'[\/]'));
  return FirmwareBuild(File(path).absolute.path, parts.length > 1 ? parts[parts.length - 2] : parts.last);
}
