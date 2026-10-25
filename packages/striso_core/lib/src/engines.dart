// The engines the virtual board loaded from its engine folder (sv_options.engine_dir), as the
// firmware reports them (Stce, docs/flows.md 10): which voice-list entries each loaded library
// gave, the colour the board shows them in, and the libraries it refused with its reason. The app
// shows only this; it never works out what loaded itself.
//
//   e engines <abi> <files>
//   e ok <first> <count> <rrggbb> <id> <file>
//   e err <reason> <file>|<detail>
//   e end

/// A library the firmware loaded: its voices are the Stcv entries [first] .. [first] + [count] - 1.
class LoadedEngine {
  final int first, count;

  /// The colour the board gives its voices (0xRRGGBB).
  final int color;

  /// The engine's id, as in the voice list.
  final String id;

  /// The library's file name in the engine folder.
  final String file;
  const LoadedEngine(this.first, this.count, this.color, this.id, this.file);
  bool hasVoice(int index) => index >= first && index < first + count;
  @override
  String toString() => 'e ok $first $count ${color.toRadixString(16).padLeft(6, '0')} $id $file';
}

/// A library the firmware refused (none of it is in the voice list), or left partly out (`full`).
class RefusedEngine {
  /// One word: library, entry, component, abi, voices, memory, full (or one the app does not know
  /// yet, shown as it is).
  final String reason;
  final String file;

  /// The firmware's detail: the OS's message for `library`, `<its abi> <the build's>` for `abi`,
  /// `<its voices> <the board's>` for `voices`, how many were left out for `full`.
  final String detail;
  const RefusedEngine(this.reason, this.file, this.detail);
  @override
  String toString() => 'e err $reason $file|$detail';
}

class EngineReport {
  /// The engine ABI this build loads (NSC_ABI), and how many library files it found.
  final int abi, files;
  final List<LoadedEngine> loaded;
  final List<RefusedEngine> refused;
  const EngineReport(this.abi, this.files, this.loaded, this.refused);

  LoadedEngine? loadedFile(String file) => loaded.where((e) => e.file == file).firstOrNull;
  RefusedEngine? refusedFile(String file) => refused.where((e) => e.file == file).firstOrNull;

  /// The loaded engine a voice-list entry belongs to (null: the build's own).
  LoadedEngine? ofVoice(int index) => loaded.where((e) => e.hasVoice(index)).firstOrNull;
}

final _head = RegExp(r'^e engines (\d+) (\d+)$');
final _ok = RegExp(r'^e ok (\d+) (\d+) ([0-9a-fA-F]{6}) (\S+) (.+)$');
final _err = RegExp(r'^e err (\S+) ([^|]+)\|(.*)$');

/// Whether a console line belongs to the Stce reply.
bool isEngineReportLine(String line) => line.trim().startsWith('e ');

/// The Stce reply (its lines, "e engines .." .. "e end"); null when it is not a whole one.
EngineReport? parseEngineReport(List<String> lines) {
  int? abi, files;
  final loaded = <LoadedEngine>[];
  final refused = <RefusedEngine>[];
  var ended = false;
  for (final raw in lines) {
    final l = raw.trim();
    if (!l.startsWith('e ')) continue;
    if (l == 'e end') {
      ended = true;
      break;
    }
    final h = _head.firstMatch(l);
    if (h != null) {
      abi = int.parse(h.group(1)!);
      files = int.parse(h.group(2)!);
      continue;
    }
    if (abi == null) continue;
    final o = _ok.firstMatch(l);
    if (o != null) {
      loaded.add(LoadedEngine(int.parse(o.group(1)!), int.parse(o.group(2)!), int.parse(o.group(3)!, radix: 16), o.group(4)!, o.group(5)!.trim()));
      continue;
    }
    final e = _err.firstMatch(l);
    if (e != null) refused.add(RefusedEngine(e.group(1)!, e.group(2)!.trim(), e.group(3)!.trim()));
  }
  if (!ended || abi == null || files == null) return null;
  return EngineReport(abi, files, loaded, refused);
}
