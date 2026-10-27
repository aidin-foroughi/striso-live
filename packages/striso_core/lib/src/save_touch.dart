// Save to Striso: the config the firmware built (Stcc: its user page with the live touch settings,
// key factors and voice keys) copied to the board's UF2 bootloader drive as NEWCFG.UF2. The app
// builds no config: it has asked the board for Stcc, put it into the bootloader (console command
// B) and let go of it.
//
// Safety: only a drive whose INFO_UF2.TXT mentions the Striso is used, and only when there is
// exactly one; the current CONFIG.UF2 is backed up first; every block written must be a Striso
// config block inside the config area (0x08020000-0x08040000).

import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

const int configStart = 0x08020000;
const int configEnd = 0x08040000;

class ConfigError implements Exception {
  final String message;
  const ConfigError(this.message);
  @override
  String toString() => message;
}

/// The bytes of a Stcc reply (`c uf2 <bytes>`, hex lines, `c end`); a ConfigError with the
/// board's reason ("c err ...") or for a reply that is not whole.
Uint8List parseConfigReply(List<String> lines) {
  final err = lines.where((l) => l.startsWith('c err')).firstOrNull;
  if (err != null) throw ConfigError('the board did not build its config: ${err.substring(5).trim()}');
  final head = lines.isEmpty ? null : RegExp(r'^c uf2 (\d+)$').firstMatch(lines.first);
  if (head == null || lines.last != 'c end') throw const ConfigError('the board\u2019s config did not arrive whole');
  final out = BytesBuilder();
  for (final l in lines.sublist(1, lines.length - 1)) {
    if (l.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(l)) throw const ConfigError('the board\u2019s config has a line that is not hex');
    for (var i = 0; i < l.length; i += 2) {
      out.addByte(int.parse(l.substring(i, i + 2), radix: 16));
    }
  }
  final data = out.takeBytes();
  if (data.length != int.parse(head.group(1)!)) throw const ConfigError('the board\u2019s config did not arrive whole');
  checkConfigUf2(data);
  return data;
}

const _magic0 = 0x0A324655, _magic1 = 0x9E5D5157, _magicEnd = 0x0AB16F30, _family = 0xA21E1295;

/// Every block of a UF2 written to the drive must be a Striso config block inside the config area.
void checkConfigUf2(Uint8List data) {
  if (data.isEmpty || data.length % 512 != 0) throw const ConfigError('REFUSED: not a UF2 file');
  final bd = ByteData.sublistView(data);
  for (var o = 0; o < data.length; o += 512) {
    final m0 = bd.getUint32(o, Endian.little), m1 = bd.getUint32(o + 4, Endian.little), fam = bd.getUint32(o + 28, Endian.little);
    final addr = bd.getUint32(o + 12, Endian.little), size = bd.getUint32(o + 16, Endian.little);
    if (m0 != _magic0 || m1 != _magic1 || fam != _family || bd.getUint32(o + 508, Endian.little) != _magicEnd) {
      throw ConfigError('REFUSED: block ${o ~/ 512} is not a Striso UF2 block');
    }
    if (!(configStart <= addr && addr + size <= configEnd)) {
      throw ConfigError('REFUSED: block ${o ~/ 512} writes 0x${addr.toRadixString(16)}, outside the config area');
    }
  }
}

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

/// Writes [config] (the board's Stcc) to the one Striso update drive, after a backup of its
/// CONFIG.UF2. [fake]: every step but the drive (its CONFIG.UF2 is then [config] itself).
Future<SaveResult> saveTouch(
  Uint8List config, {
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
    checkConfigUf2(config);
    say('Waiting for the Striso\u2019s update drive\u2026');
    String? root;
    Uint8List current;
    if (fake != null) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      current = config;
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
    say('Writing the new settings\u2026');
    if (fake != null) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (fake == 'fail') throw const ConfigError('fake save failure (--fake-save=fail)');
    } else {
      if (!isStrisoDrive(root!)) throw const ConfigError('the update drive changed: nothing written');
      final f = File(_join(root, 'NEWCFG.UF2')).openSync(mode: FileMode.write);
      try {
        f.writeFromSync(config);
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
    return SaveResult(true, 'config: ${config.length ~/ 512} blocks written (the previous config backed up to $name)', backupPath);
  } on ConfigError catch (e) {
    return SaveResult(false, e.message, backupPath);
  } catch (e) {
    return SaveResult(false, '$e', backupPath);
  }
}
