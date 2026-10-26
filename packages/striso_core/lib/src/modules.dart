// The board's engine-module slots (the firmware's doc/engines.md, "Engine modules"; research/
// board_engine_modules.md): an awva engine package (.awvapkg, research/package_format.md) is put into a slot over the console,
// the firmware checks it, keeps it in flash (Virtual: its module store file) and lists its voices
// after the built-in engines from the next start. The app sends the package's bytes and shows what
// the firmware says; it reads nothing of a package itself.
//
//   Stci 's' <length u32 LE> <bytes>   m begin ok <tag> <free> (or m err <reason>), then
//                                      m <bytes> <crc32> every 4 KB, then
//                                      m ok <slot> <id> <version> <abi>, or m err <reason>
//                                      (bytes that stop for the console's 100 ms gap: m err
//                                      timeout); a refused upload's bytes are taken and dropped,
//                                      none read as a command
//   Stco                               slot <k> empty | partial
//                                      slot <k> <id> <version> <abi> <bytes> ok | disabled: <reason>
//                                      slot end
//   Stcz <digit>                       m erased <k>, or m err <reason>

import 'dart:typed_data';

class ModuleCodes {
  static const install = 'i', slots = 'o', erase = 'z';
}

Uint8List _cmd(String code, List<int> payload) => Uint8List.fromList([0x53, 0x74, 0x63, code.codeUnitAt(0), ...payload]);

/// Stci into a slot, the package's bytes after it, in one go (the console's upload stream).
Uint8List moduleInstallCommand(List<int> package) {
  final n = package.length;
  return Uint8List.fromList([
    ..._cmd(ModuleCodes.install, [0x73, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff]),
    ...package,
  ]);
}

Uint8List moduleSlotsCommand() => _cmd(ModuleCodes.slots, const []);

Uint8List moduleEraseCommand(int slot) {
  if (slot < 0 || slot > 9) throw RangeError('bad slot $slot');
  return _cmd(ModuleCodes.erase, [0x30 + slot]);
}

enum SlotState { empty, partial, ok, disabled }

/// One slot as Stco lists it.
class ModuleSlot {
  final int slot;
  final SlotState state;

  /// The engine's id, version, engine ABI and image size (null for an empty or partial slot, or
  /// one whose header does not read).
  final String? id, version;
  final int? abi, bytes;

  /// Why a disabled one may not run, in the firmware's words.
  final String? reason;
  const ModuleSlot(this.slot, this.state, {this.id, this.version, this.abi, this.bytes, this.reason});

  bool get holdsEngine => id != null;

  @override
  bool operator ==(Object other) =>
      other is ModuleSlot &&
      other.slot == slot &&
      other.state == state &&
      other.id == id &&
      other.version == version &&
      other.abi == abi &&
      other.bytes == bytes &&
      other.reason == reason;
  @override
  int get hashCode => Object.hash(slot, state, id, version, abi, bytes, reason);
  @override
  String toString() => switch (state) {
    SlotState.empty || SlotState.partial => 'slot $slot ${state.name}',
    SlotState.ok => 'slot $slot $id $version $abi $bytes ok',
    SlotState.disabled => 'slot $slot ${id ?? '-'} ${version ?? '-'} ${abi ?? '-'} ${bytes ?? '-'} disabled: $reason',
  };
}

bool isModuleSlotLine(String line) => line.trim().startsWith('slot ');

final _slotRe = RegExp(r'^slot (\d+) (\S+) (\S+) (\S+) (\S+) (ok|disabled: (.*))$');

/// One Stco line; null when it is not one (or is `slot end`).
ModuleSlot? parseModuleSlot(String line) {
  final t = line.trim();
  final short = RegExp(r'^slot (\d+) (empty|partial)$').firstMatch(t);
  if (short != null) return ModuleSlot(int.parse(short[1]!), short[2] == 'empty' ? SlotState.empty : SlotState.partial);
  final m = _slotRe.firstMatch(t);
  if (m == null) return null;
  String? word(String s) => s == '-' ? null : s;
  final ok = m[6] == 'ok';
  return ModuleSlot(
    int.parse(m[1]!),
    ok ? SlotState.ok : SlotState.disabled,
    id: word(m[2]!),
    version: word(m[3]!),
    abi: int.tryParse(m[4]!),
    bytes: int.tryParse(m[5]!),
    reason: ok ? null : m[7]!.trim(),
  );
}

/// The slots, from Stco's lines; null without its `slot end` (a firmware that has no slots does
/// not answer).
List<ModuleSlot>? parseModuleSlots(List<String> lines) {
  if (!lines.any((l) => l.trim() == 'slot end')) return null;
  return [for (final l in lines) ?parseModuleSlot(l)];
}

/// A line of an install (Stci) or an erase (Stcz): what the firmware said.
sealed class ModuleLine {
  const ModuleLine();
}

/// The upload is taken: the image tag the board runs (its architecture) and its free slots.
class ModuleBegin extends ModuleLine {
  final String tag;
  final int free;
  const ModuleBegin(this.tag, this.free);
}

/// So many bytes arrived, and their crc32 (zlib's).
class ModuleProgress extends ModuleLine {
  final int bytes, crc;
  const ModuleProgress(this.bytes, this.crc);
}

/// Installed: the slot and the engine in it.
class ModuleDone extends ModuleLine {
  final int slot, abi;
  final String id, version;
  const ModuleDone(this.slot, this.id, this.version, this.abi);
}

class ModuleErased extends ModuleLine {
  final int slot;
  const ModuleErased(this.slot);
}

/// Refused, with the firmware's reason.
class ModuleError extends ModuleLine {
  final String reason;
  const ModuleError(this.reason);
}

/// An `m ...` line of an install or an erase; null when it is not one.
ModuleLine? parseModuleLine(String line) {
  final t = line.trim();
  if (!t.startsWith('m ')) return null;
  final w = t.substring(2);
  if (w.startsWith('err ')) return ModuleError(w.substring(4).trim());
  if (w == 'err') return const ModuleError('');
  var m = RegExp(r'^begin ok (\S+) (\d+)$').firstMatch(w);
  if (m != null) return ModuleBegin(m[1]!, int.parse(m[2]!));
  m = RegExp(r'^ok (\d+) (\S+) (\S+) (\d+)$').firstMatch(w);
  if (m != null) return ModuleDone(int.parse(m[1]!), m[2]!, m[3]!, int.parse(m[4]!));
  m = RegExp(r'^erased (\d+)$').firstMatch(w);
  if (m != null) return ModuleErased(int.parse(m[1]!));
  m = RegExp(r'^(\d+) ([0-9a-fA-F]{1,8})$').firstMatch(w);
  if (m != null) return ModuleProgress(int.parse(m[1]!), int.parse(m[2]!, radix: 16));
  return null;
}

final _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// zlib's crc32 of [bytes] from [start] to [end], continuing [crc] (crc32(crc32(0, a), b) =
/// crc32(0, a b)), to check the firmware's progress lines against what was sent.
int crc32(List<int> bytes, {int crc = 0, int start = 0, int? end}) {
  var c = crc ^ 0xffffffff;
  for (var i = start; i < (end ?? bytes.length); i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// How an install ended.
class ModuleInstall {
  /// The slot it went into (null when it did not).
  final ModuleDone? done;

  /// The firmware's reason, or the app's when the bytes or the reply went wrong.
  final String? error;

  /// The image tag the board takes, from its begin line.
  final String? tag;
  const ModuleInstall({this.done, this.error, this.tag});
  bool get ok => done != null;
}
