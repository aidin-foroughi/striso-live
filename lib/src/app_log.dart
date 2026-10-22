// The console drawer's log, also written to a file: every app error ends up here (never in a
// native dialog).

import 'dart:io';

import 'package:flutter/foundation.dart';

enum LogKind { info, out, err }

class LogLine {
  final DateTime t;
  final String text;
  final LogKind kind;
  const LogLine(this.t, this.text, this.kind);
  String get stamp {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }
}

class AppLog extends ChangeNotifier {
  static const maxLines = 400;
  final lines = <LogLine>[];
  IOSink? _sink;
  String? filePath;

  /// Opens (and rotates at 1 MB) the log file in [dir].
  void openFile(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final f = File('$dir${Platform.pathSeparator}striso-live.log');
      if (f.existsSync() && f.lengthSync() > 1 << 20) {
        final old = File('${f.path}.1');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      _sink = f.openWrite(mode: FileMode.append);
      filePath = f.path;
      _sink!.writeln('---- Striso Live started ${DateTime.now().toIso8601String()} ----');
    } catch (e) {
      add('could not open the log file in $dir: $e', LogKind.err);
    }
  }

  void add(String text, [LogKind kind = LogKind.info]) {
    final l = LogLine(DateTime.now(), text, kind);
    lines.add(l);
    if (lines.length > maxLines) lines.removeRange(0, lines.length - maxLines);
    try {
      _sink?.writeln(
        '${l.t.toIso8601String()} ${kind == LogKind.err
            ? 'ERR '
            : kind == LogKind.out
            ? 'OUT '
            : ''}$text',
      );
    } catch (_) {}
    notifyListeners();
  }

  void info(String t) => add(t);
  void err(String t) => add(t, LogKind.err);

  Future<void> close() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}

/// The one log of the app.
final appLog = AppLog();
