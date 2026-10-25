// The board's sound presets on the console (striso-control-firmware doc/presets_console.md): the
// list (factory then the user's), one preset's text, an upload (a file to install, or the current
// voice saved under a title), a delete, and one opened as the sound with the firmware's report
// of what it clamped and skipped. The app keeps no preset data: it sends files and titles and
// shows what the board reads back.

import 'dart:convert';
import 'dart:typed_data';

/// The commands' code letters, in one place.
abstract final class PresetCodes {
  static const list = 'J', text = 'j', upload = 'F', delete = 'x', open = 'O';
}

/// Ids at and above this are factory presets (the voice entries); below, the user's.
const factoryPresetBase = 0x8000;

/// A preset text's limit, a title's and a description's (bytes), kind 2's fields.
const presetMaxText = 8192, presetMaxTitle = 63, presetMaxDescription = 255, presetMaxFields = 1024;

Uint8List _cmd(String code, List<int> payload) => Uint8List.fromList([0x53, 0x74, 0x63, code.codeUnitAt(0), ...payload]);
List<int> _u16(int id) {
  if (id < 1 || id > 0xffff) throw RangeError('bad preset id $id');
  return [id & 0xff, id >> 8];
}

Uint8List presetListCommand() => _cmd(PresetCodes.list, const []);
Uint8List presetTextCommand(int id) => _cmd(PresetCodes.text, _u16(id));
Uint8List presetDeleteCommand(int id) => _cmd(PresetCodes.delete, _u16(id));
Uint8List presetOpenCommand(int id) => _cmd(PresetCodes.open, _u16(id));

/// An upload: kind 1 a preset's text (a file to install), kind 2 the current voice saved with a
/// title and a description (the fields as JSON; the board writes the preset). The bytes follow
/// the 5-byte payload.
Uint8List presetUploadCommand(int kind, List<int> bytes) {
  final n = bytes.length;
  return Uint8List.fromList([
    ..._cmd(PresetCodes.upload, [kind, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff]),
    ...bytes,
  ]);
}

/// Kind 2's bytes: `{"title": ..., "description": ...}`.
List<int> saveAsBytes(String title, String description) => utf8.encode(jsonEncode({'title': title.trim(), 'description': description.trim()}));

class BoardPreset {
  final int id;

  /// The engine's id, '?' for a user preset that no longer reads.
  final String engine;

  /// The firmware version it was saved with (null: a factory preset, or none given).
  final String? version;
  final String title;
  final String? description;
  const BoardPreset(this.id, this.engine, this.title, {this.version, this.description});
  bool get factory => id >= factoryPresetBase;
  bool get readable => engine != '?';
  @override
  String toString() => 'J $id $engine ${version ?? '-'} $title';
}

class PresetList {
  final List<BoardPreset> presets;

  /// False: this firmware has no preset store (factory presets only).
  final bool storeOn;
  const PresetList(this.presets, {required this.storeOn});
  Iterable<BoardPreset> get user => presets.where((p) => !p.factory);
}

final _jLine = RegExp(r'^J (\d+) (\S+) (\S+) (.*)$');
final _jEnd = RegExp(r'^J end (\d+)$');

bool isPresetListLine(String l) => l.trim().startsWith('J ');

/// The StcJ reply; null when it is not a whole one. The title runs to the first `|`, the
/// description is the rest (factory presets have none).
PresetList? parsePresetList(List<String> lines) {
  final out = <BoardPreset>[];
  var storeOn = true, ended = false;
  for (final raw in lines) {
    final l = raw.trimRight();
    if (_jEnd.hasMatch(l)) {
      ended = true;
      break;
    }
    if (l == 'J store off') {
      storeOn = false;
      continue;
    }
    final m = _jLine.firstMatch(l);
    if (m == null) continue;
    final rest = m[4]!;
    final bar = rest.indexOf('|');
    final title = (bar < 0 ? rest : rest.substring(0, bar)).trim();
    final desc = bar < 0 ? null : rest.substring(bar + 1).trim();
    out.add(BoardPreset(int.parse(m[1]!), m[2]!, title, version: m[3] == '-' ? null : m[3], description: desc == null || desc.isEmpty ? null : desc));
  }
  return ended ? PresetList(out, storeOn: storeOn) : null;
}

/// A short reply: `<code> ok <id>` or `<code> err <why>`.
class PresetReply {
  final bool ok;
  final int? id;
  final String? why;
  const PresetReply.ok(this.id) : ok = true, why = null;
  const PresetReply.err(this.why) : ok = false, id = null;
  @override
  String toString() => ok ? 'ok $id' : 'err $why';
}

PresetReply? parsePresetReply(String code, String line) {
  final l = line.trim();
  final ok = RegExp('^$code ok (\\d+)\$').firstMatch(l);
  if (ok != null) return PresetReply.ok(int.parse(ok[1]!));
  final err = RegExp('^$code err (.+)\$').firstMatch(l);
  if (err != null) return PresetReply.err(err[1]!.trim());
  return null;
}

/// Stcj's reply: the text as it was stored (the lines joined with \n, the final \n when the byte
/// count has it), or the firmware's reason.
({String? text, String? why})? parsePresetText(List<String> lines) {
  int? want;
  final body = <String>[];
  for (final raw in lines) {
    final l = raw.replaceAll('\r', '');
    if (want == null) {
      final err = RegExp(r'^j err (.+)$').firstMatch(l.trim());
      if (err != null) return (text: null, why: err[1]!.trim());
      final h = RegExp(r'^j (\d+) (\d+)$').firstMatch(l.trim());
      if (h != null) want = int.parse(h[2]!);
      continue;
    }
    if (l == 'j end') {
      var t = body.join('\n');
      if (utf8.encode(t).length + 1 == want) t = '$t\n';
      return (text: t, why: null);
    }
    final err = RegExp(r'^j err (.+)$').firstMatch(l.trim());
    if (err != null) return (text: null, why: err[1]!.trim());
    body.add(l);
  }
  return null;
}

/// What StcO did: the voice it plays, and when the preset was not exact for this engine, how many
/// values were clamped, skipped and missing, and which (up to 16 names each).
class OpenReport {
  final bool ok;
  final int? id, voice;
  final bool exact;
  final int clamped, skipped, missing;
  final List<String> clampedNames, skippedNames;
  final String? why;
  const OpenReport({
    required this.ok,
    this.id,
    this.voice,
    this.exact = false,
    this.clamped = 0,
    this.skipped = 0,
    this.missing = 0,
    this.clampedNames = const [],
    this.skippedNames = const [],
    this.why,
  });
}

final _oExact = RegExp(r'^O ok (\d+) voice (\d+) exact$');
final _oReport = RegExp(r'^O ok (\d+) voice (\d+) clamped (\d+) skipped (\d+) missing (\d+)$');

bool isOpenLine(String l) => l.trim().startsWith('O ');

/// Whether an open reply is complete with these lines: an error, exact, or a report whose name
/// lines (clamped, skipped) have come.
bool openDone(List<String> lines) {
  final r = parseOpenReport(lines);
  if (r == null) return false;
  if (!r.ok || r.exact) return true;
  return (r.clamped == 0 || r.clampedNames.isNotEmpty) && (r.skipped == 0 || r.skippedNames.isNotEmpty);
}

OpenReport? parseOpenReport(List<String> lines) {
  OpenReport? head;
  var clampedNames = const <String>[], skippedNames = const <String>[];
  for (final raw in lines) {
    final l = raw.trim();
    final err = RegExp(r'^O err (.+)$').firstMatch(l);
    if (err != null) return OpenReport(ok: false, why: err[1]!.trim());
    final e = _oExact.firstMatch(l);
    if (e != null) return OpenReport(ok: true, id: int.parse(e[1]!), voice: int.parse(e[2]!), exact: true);
    final r = _oReport.firstMatch(l);
    if (r != null) {
      head = OpenReport(
        ok: true,
        id: int.parse(r[1]!),
        voice: int.parse(r[2]!),
        clamped: int.parse(r[3]!),
        skipped: int.parse(r[4]!),
        missing: int.parse(r[5]!),
      );
      continue;
    }
    if (l.startsWith('O clamped ')) clampedNames = l.substring(10).trim().split(' ');
    if (l.startsWith('O skipped ')) skippedNames = l.substring(10).trim().split(' ');
  }
  if (head == null) return null;
  return OpenReport(
    ok: true,
    id: head.id,
    voice: head.voice,
    clamped: head.clamped,
    skipped: head.skipped,
    missing: head.missing,
    clampedNames: clampedNames,
    skippedNames: skippedNames,
  );
}

/// What the app shows of a preset file before it is installed: its title, engine, description
/// (JSON for display only; the board checks and stores the text as it is).
({String? title, String? engine, String? description, bool preset}) describePresetFile(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map) return (title: null, engine: null, description: null, preset: false);
    final e = j['engine'];
    return (
      title: j['title'] is String ? j['title'] as String : null,
      engine: e is Map && e['id'] is String ? e['id'] as String : null,
      description: j['description'] is String ? j['description'] as String : null,
      preset: j['format'] == 'awva-preset/1',
    );
  } catch (_) {
    return (title: null, engine: null, description: null, preset: false);
  }
}
