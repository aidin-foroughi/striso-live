// Save touch settings and key factors into the Striso's config through its UF2 bootloader drive:
// the app's version of tools/striso.py save_touch()/config_update(). The app has already put the
// board into the bootloader (console command B) and let go of it.
//
// Safety: only a drive whose INFO_UF2.TXT mentions the Striso is used, and only when there is
// exactly one; the current CONFIG.UF2 is backed up first; the file written must read back as the
// intended records and every block must lie inside the config area (0x08020000-0x08040000).

import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

import 'config_uf2.dart';
import 'voice_keys.dart';

/// Roots where an update drive can appear.
List<String> candidateRoots() {
  if (Platform.isWindows) return [for (final l in 'CDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) '$l:\\'];
  final roots = <String>[];
  void list(String dir) {
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is Directory) roots.add(e.path);
      }
    } catch (_) {}
  }

  if (Platform.isMacOS) {
    list('/Volumes');
  } else {
    final user = Platform.environment['USER'] ?? '';
    list('/media/$user');
    list('/run/media/$user');
    list('/media');
  }
  return roots;
}

bool isStrisoDrive(String root) {
  try {
    return File(
      '$root${root.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}INFO_UF2.TXT',
    ).readAsStringSync(encoding: latin1).contains('Striso');
  } catch (_) {
    return false;
  }
}

List<String> findStrisoDrives({List<String> Function()? roots}) => (roots ?? candidateRoots)().where(isStrisoDrive).toList();

class SaveResult {
  final bool ok;
  final String message;
  final String? backupPath;
  const SaveResult(this.ok, this.message, [this.backupPath]);
}

String _stamp(DateTime d) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)}_${p(d.hour)}${p(d.minute)}${p(d.second)}';
}

String _join(String a, String b) => a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

/// A fake drive's contents for --fake-save / tests.
final Uint8List fakeDriveConfig = configUf2([('iGoct   ', '0       '), ('fCfacC_2', '1.07    ')]);

Future<SaveResult> saveTouch(
  TouchValues values, {
  List<ConfigEdit> voiceKeys = const [],
  required String backupDir,
  void Function(String text)? progress,
  String? fake, // null, 'ok' or 'fail': no drive is touched
  List<String> Function()? roots,
  Duration driveTimeout = const Duration(seconds: 30),
  Duration rebootTimeout = const Duration(seconds: 60),
}) async {
  final say = progress ?? (_) {};
  String? backupPath;
  try {
    // check the values before anything else happens
    buildConfig(fakeDriveConfig, values, voiceKeys: voiceKeys);
    say('Waiting for the Striso\u2019s update drive\u2026');
    String? root;
    Uint8List current;
    if (fake != null) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      current = fakeDriveConfig;
    } else {
      final t0 = DateTime.now();
      var drives = findStrisoDrives(roots: roots);
      while (drives.isEmpty) {
        if (DateTime.now().difference(t0) > driveTimeout) throw const ConfigError('timed out waiting for the Striso update drive');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        drives = findStrisoDrives(roots: roots);
      }
      if (drives.length > 1) throw ConfigError('more than one Striso update drive (${drives.join(', ')}): unplug the others');
      root = drives.first;
      current = File(_join(root, 'CONFIG.UF2')).readAsBytesSync();
    }
    say('Backing up the current settings\u2026');
    Directory(backupDir).createSync(recursive: true);
    backupPath = _join(backupDir, 'config_${_stamp(DateTime.now())}.uf2');
    File(backupPath).writeAsBytesSync(current, flush: true);
    final built = buildConfig(current, values, voiceKeys: voiceKeys);
    say('Writing the new settings\u2026');
    if (fake != null) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (fake == 'fail') throw const ConfigError('fake save failure (--fake-save=fail)');
    } else {
      if (!isStrisoDrive(root!)) throw const ConfigError('the update drive changed: nothing written');
      final f = File(_join(root, 'NEWCFG.UF2')).openSync(mode: FileMode.write);
      try {
        f.writeFromSync(built.data);
        f.flushSync();
      } finally {
        f.closeSync();
      }
    }
    say('Waiting for the Striso to restart\u2026');
    if (fake == null) {
      final t0 = DateTime.now();
      while (File(_join(root!, 'INFO_UF2.TXT')).existsSync()) {
        if (DateTime.now().difference(t0) > rebootTimeout) throw const ConfigError('timed out waiting for the Striso to restart');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    final name = backupPath.split(Platform.pathSeparator).last;
    return SaveResult(true, 'config: ${built.recs.length} entries (${built.updates.length} set, previous config backed up to $name)', backupPath);
  } on ConfigError catch (e) {
    return SaveResult(false, e.message, backupPath);
  } catch (e) {
    return SaveResult(false, '$e', backupPath);
  }
}
