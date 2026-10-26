// The engine library (research/board_engine_modules.md 4.3): awva engine packages (.nsc, the
// firmware's tools/module/nsc_pack.py), one file each, kept in <app data>/engines/ to put on a
// board's engine slots, the Striso's or Virtual's, over the console (Stci), e.g.
//   %APPDATA%\Striso Live\engines\accordion.nsc
// The app reads nothing of a package: the firmware checks it, keeps it in a slot and says what it
// is (Stci, Stco); a package carries an image for the board and one for each computer Virtual runs
// on.

import 'dart:io';

import 'package:archive/archive.dart';

import 'firmware_library.dart';

/// A package in the library: its file, and its name (the file's, without `.nsc`).
class EnginePackage {
  final String path;
  const EnginePackage(this.path);
  String get name => _stem(_base(path));
  @override
  bool operator ==(Object other) => other is EnginePackage && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;
String _stem(String file) {
  final d = file.lastIndexOf('.');
  return d > 0 ? file.substring(0, d) : file;
}

bool _isPackage(String name) => name.toLowerCase().endsWith('.nsc');

/// The packages in [dir], by name.
List<EnginePackage> findEngines(String? dir) {
  if (dir == null) return const [];
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <EnginePackage>[];
  try {
    for (final e in d.listSync()) {
      if (e is File && _isPackage(e.path)) out.add(EnginePackage(e.absolute.path));
    }
  } catch (_) {}
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Whether [source] is an engine to install (not a firmware build): a package, or a zip of
/// packages without a build's manifest.
bool isEngineSource(String source) {
  final lower = source.toLowerCase();
  if (!lower.endsWith('.zip')) return _isPackage(lower);
  try {
    final zip = ZipDecoder().decodeBytes(File(source).readAsBytesSync());
    if (zip.files.any((f) => f.isFile && _base(f.name) == 'manifest.json')) return false;
    return zip.files.any((f) => f.isFile && _isPackage(f.name));
  } catch (_) {
    return false;
  }
}

/// Copies the packages of [source] (a package, or a zip of them) into [enginesDir], replacing one
/// of the same name, and returns their paths in the library.
List<String> installEngine(String source, String enginesDir) {
  final src = File(source);
  if (!src.existsSync()) throw FirmwareInstallError('$source is not there');
  final files = <String, List<int>>{};
  if (source.toLowerCase().endsWith('.zip')) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(src.readAsBytesSync());
    } catch (e) {
      throw FirmwareInstallError('${_base(source)} is not a zip: $e');
    }
    for (final f in zip.files.where((f) => f.isFile && _isPackage(f.name))) {
      files[_base(f.name)] = f.content as List<int>;
    }
    if (files.isEmpty) throw const FirmwareInstallError('the zip has no engine package (.nsc)');
  } else {
    if (!_isPackage(source)) throw const FirmwareInstallError('pick an engine package (.nsc) or a zip of them');
    files[_base(source)] = src.readAsBytesSync();
  }
  final sep = Platform.pathSeparator;
  final dir = Directory(enginesDir)..createSync(recursive: true);
  final out = <String>[];
  for (final e in files.entries) {
    final dest = '${dir.absolute.path}$sep${safeFolder(_stem(e.key))}.nsc';
    final tmp = File('$dest.incoming')..writeAsBytesSync(e.value, flush: true);
    tmp.renameSync(dest);
    out.add(dest);
  }
  return out;
}
