// The engines Virtual can add to a build (docs/flows.md 10): awva engine components (one engine
// per library, awva/component/include/nsc/nsc.h) kept in <app data>/engines/, a folder each with
// the library and the manifest the awva build writes next to it (<name>.json: id, name, summary,
// abi, version, presets), e.g.
//   %APPDATA%\Striso Live\engines\sax\sax.dll + sax.json
// The firmware loads the ticked ones from one folder the app stages per run (sv_options
// .engine_dir) and reports what it did (Stce); the app reads nothing of a library itself.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'firmware_library.dart';

/// An engine library's extension on this system.
String engineExt() => Platform.isWindows ? 'dll' : (Platform.isMacOS ? 'dylib' : 'so');

/// What the awva build says about a component (its `<name>.json`, written by nsc_manifest from the
/// descriptor): how the user knows it, and the engine ABI it was built for.
class EngineManifest {
  final String id;
  final String? name, summary, version;
  final int? abi;
  final List<String> presets;
  const EngineManifest({required this.id, this.name, this.summary, this.version, this.abi, this.presets = const []});

  /// Null when it is not a component manifest (no id, or not JSON).
  static EngineManifest? tryParse(String json) {
    final Object? j;
    try {
      j = jsonDecode(json);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final Map<Object?, Object?> m = j;
    String? str(String k) => m[k] is String && (m[k] as String).trim().isNotEmpty ? (m[k] as String).trim() : null;
    final id = str('id');
    if (id == null) return null;
    final p = m['presets'];
    return EngineManifest(
      id: id,
      name: str('name'),
      summary: str('summary'),
      version: str('version'),
      abi: m['abi'] is int ? m['abi'] as int : null,
      presets: p is List ? [for (final x in p) '$x'] : const [],
    );
  }
}

class EngineComponent {
  /// The library file.
  final String path;

  /// Its folder's name in the engine folder (the file's own name for one elsewhere).
  final String name;
  final EngineManifest? manifest;
  const EngineComponent(this.path, this.name, {this.manifest});

  String get title => manifest?.name ?? name;
  String? get description => manifest?.summary;

  /// "0a00222 · 4 presets": what the row says on its right.
  String get facts => [?manifest?.version, if (manifest != null && manifest!.presets.isNotEmpty) '${manifest!.presets.length} presets'].join(' · ');

  /// The file's stamp (modified time and size): a refusal is true for this file only.
  int get stamp {
    try {
      final st = File(path).statSync();
      return st.modified.millisecondsSinceEpoch ^ st.size;
    } catch (_) {
      return -1;
    }
  }

  @override
  bool operator ==(Object other) => other is EngineComponent && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;
String _stem(String file) {
  final d = file.lastIndexOf('.');
  return d > 0 ? file.substring(0, d) : file;
}

/// A library file anywhere, as a component: its folder's name, and the manifest beside it
/// (`<stem>.json`) when there is a readable one.
EngineComponent engineOf(String path) {
  final abs = File(path).absolute.path;
  final parts = abs.split(RegExp(r'[\\/]'));
  final name = parts.length > 1 ? parts[parts.length - 2] : parts.last;
  final mf = File('${File(abs).parent.path}${Platform.pathSeparator}${_stem(parts.last)}.json');
  EngineManifest? m;
  try {
    if (mf.existsSync()) m = EngineManifest.tryParse(mf.readAsStringSync());
  } catch (_) {}
  return EngineComponent(abs, name, manifest: m);
}

/// The components in [dir]: one per folder (the staging folder, a dot folder, is not one), by
/// title.
List<EngineComponent> findEngines(String? dir) {
  if (dir == null) return const [];
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <EngineComponent>[];
  try {
    for (final e in d.listSync()) {
      if (e is! Directory || _base(e.path).startsWith('.')) continue;
      final libs = e.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.${engineExt()}')).toList();
      if (libs.length == 1) out.add(engineOf(libs.single.path));
    }
  } catch (_) {}
  out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return out;
}

/// Whether [source] is an engine to install (not a firmware build): a library that is not
/// striso_virtual's, or a zip with an engine's manifest and no build manifest.
bool isEngineSource(String source) {
  final lower = source.toLowerCase();
  if (!lower.endsWith('.zip')) return lower.endsWith('.${engineExt()}') && _base(source) != virtualLibName();
  try {
    final zip = ZipDecoder().decodeBytes(File(source).readAsBytesSync());
    if (zip.files.any((f) => f.isFile && _base(f.name) == 'manifest.json')) return false;
    return zip.files.any((f) => f.isFile && f.name.toLowerCase().endsWith('.${engineExt()}'));
  } catch (_) {
    return false;
  }
}

/// Installs an engine into [enginesDir] and returns its library's path:
/// - a zip: one library for this system and its manifest (`<stem>.json`, the awva build's), kept
///   as `DIR/<id>/`;
/// - a library file: copied with the manifest beside it, if there is one, into `DIR/<id or its
///   name>/`.
/// What was there for that engine is replaced. macOS: the quarantine attribute is cleared.
Future<String> installEngine(String source, String enginesDir, {Future<ProcessResult> Function(String, List<String>)? run}) async {
  final src = File(source);
  if (!src.existsSync()) throw FirmwareInstallError('$source is not there');
  final sep = Platform.pathSeparator;
  final ext = engineExt();
  final files = <String, List<int>>{}; // file name -> bytes
  String lib;
  EngineManifest? m;
  if (source.toLowerCase().endsWith('.zip')) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(src.readAsBytesSync());
    } catch (e) {
      throw FirmwareInstallError('${_base(source)} is not a zip: $e');
    }
    final libs = zip.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.$ext')).toList();
    if (libs.isEmpty) throw FirmwareInstallError('the zip has no engine library for this computer (.$ext)');
    if (libs.length > 1) throw const FirmwareInstallError('the zip has more than one engine library: install them one by one');
    lib = _base(libs.single.name);
    final mf = zip.files.where((f) => f.isFile && _base(f.name) == '${_stem(lib)}.json').firstOrNull;
    if (mf == null) throw FirmwareInstallError('the zip has no ${_stem(lib)}.json (the engine\'s manifest)');
    final text = utf8.decode(mf.content as List<int>, allowMalformed: true);
    m = EngineManifest.tryParse(text);
    if (m == null) throw FirmwareInstallError('${_stem(lib)}.json is not an engine manifest');
    files[lib] = libs.single.content as List<int>;
    files['${_stem(lib)}.json'] = utf8.encode(text);
  } else {
    if (!source.toLowerCase().endsWith('.$ext')) throw FirmwareInstallError('pick an engine zip or a .$ext');
    lib = _base(source);
    files[lib] = src.readAsBytesSync();
    final mf = File('${src.parent.path}$sep${_stem(lib)}.json');
    if (mf.existsSync()) {
      final text = mf.readAsStringSync();
      m = EngineManifest.tryParse(text);
      if (m != null) files['${_stem(lib)}.json'] = utf8.encode(text);
    }
  }
  final dest = '${Directory(enginesDir).absolute.path}$sep${safeFolder(m?.id ?? _stem(lib))}';
  final tmp = Directory('$dest.incoming');
  if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  tmp.createSync(recursive: true);
  for (final e in files.entries) {
    File('${tmp.path}$sep${e.key}').writeAsBytesSync(e.value, flush: true);
  }
  final old = Directory(dest);
  if (old.existsSync()) old.deleteSync(recursive: true);
  tmp.renameSync(dest);
  if (!await clearQuarantine(dest, run: run)) throw FirmwareInstallError('macOS keeps it in quarantine (xattr failed on $dest)');
  return '$dest$sep$lib';
}

/// The folder the firmware loads for one run: a fresh one under DIR/.loaded/ with a copy of each
/// component, named by its folder so the firmware's order (file names) is the list's. Returns
/// the folder and which component each staged file is; older stagings are removed (the board
/// that used them is gone). Null with no components.
({String dir, Map<String, String> files})? stageEngines(List<EngineComponent> engines, String enginesDir) {
  final sep = Platform.pathSeparator;
  final root = Directory('$enginesDir$sep.loaded');
  if (root.existsSync()) {
    for (final e in root.listSync()) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {} // still loaded somewhere: left for the next time
    }
  }
  if (engines.isEmpty) return null;
  final d = Directory('${root.path}$sep${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
  final files = <String, String>{};
  for (final e in engines) {
    var name = '${safeFolder(e.name)}.${engineExt()}';
    for (var n = 2; files.containsKey(name); n++) {
      name = '${safeFolder(e.name)}-$n.${engineExt()}';
    }
    File(e.path).copySync('${d.path}$sep$name');
    files[name] = e.path;
  }
  return (dir: d.path, files: files);
}
