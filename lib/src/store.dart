// Preferences and saved sounds in a JSON file in the app's support folder (the desktop
// counterpart of the web app's localStorage keys). Writes go to a temp file first.

import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// The app's folder for settings, logs and backups.
String appSupportDir() {
  final env = Platform.environment;
  final override = env['STRISO_LIVE_HOME'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) return '${env['APPDATA'] ?? env['USERPROFILE'] ?? '.'}\\Striso Live';
  if (Platform.isMacOS) return '${env['HOME'] ?? '.'}/Library/Application Support/Striso Live';
  return '${env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config'}/striso-live';
}

class Store {
  final String? path; // null: in memory only (tests)
  final Map<String, Object?> _data = {};

  Store(this.path) {
    final p = path;
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) _data.addAll(j.cast<String, Object?>());
      }
    } catch (e) {
      appLog.err('settings file unreadable, starting fresh: $e');
    }
  }

  Store.memory() : path = null;

  T? get<T>(String key) {
    final v = _data[key];
    return v is T ? v : null;
  }

  Object? raw(String key) => _data[key];

  bool set(String key, Object? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    return _flush();
  }

  bool _flush() {
    final p = path;
    if (p == null) return true;
    try {
      final f = File(p);
      f.parent.createSync(recursive: true);
      final tmp = File('$p.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(_data), flush: true);
      tmp.renameSync(p);
      return true;
    } catch (e) {
      appLog.err('could not save settings: $e');
      return false;
    }
  }
}
