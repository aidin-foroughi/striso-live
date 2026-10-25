// The board's sound presets in the Play column (striso-control-firmware doc/presets_console.md):
// ON THE STRISO, the user's
// presets for this engine as the board lists them (StcJ), each with Load, Share… and Delete;
// + Save as… (title and description: the board writes the preset), Install… (or drop .json files
// on the window). A preset made for another version of the engine loads with the board's report
// of what it clamped and skipped, under the header. The app keeps no preset data of its own.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'play_tab.dart' show ListRow;

/// ON THE STRISO: the user's presets on the board for [engine], Save as…, Install….
class BoardPresetsSection extends StatelessWidget {
  final AppController ctl;
  final String engine;
  final Color dot;
  const BoardPresetsSection(this.ctl, this.engine, this.dot, {super.key});

  @override
  Widget build(BuildContext context) {
    final list = ctl.boardPresets;
    if (list == null) return const SizedBox.shrink(); // a firmware without presets lists nothing
    final mine = ctl.userPresetsOf(engine);
    final open = ctl.lastOpen;
    final others = list.user.length - mine.length;
    return Column(
      key: const Key('board-presets'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.xl),
        const Micro('On the Striso'),
        const SizedBox(height: Space.xs),
        if (!list.storeOn)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Text('This firmware keeps no presets of your own: its factory presets are above.', style: ui(TypeSize.body, color: Pal.text2)),
          )
        else ...[
          if (mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Text('Presets you save on the Striso appear here.', style: ui(TypeSize.body, color: Pal.text2)),
            ),
          for (final p in mine)
            ListRow(
              key: Key('board-preset-${p.id}'),
              label: p.title.isEmpty ? '(untitled)' : p.title,
              current: ctl.openPreset?.id == p.id,
              pending: ctl.presetBusy && open?.preset.id == p.id,
              dot: dot,
              tooltip: [p.title, ?p.description, if (p.version != null) 'saved with ${p.version}'].join('\n'),
              onTap: () => ctl.openBoardPreset(p),
              menu: (context) => boardPresetMenu(context, ctl, p),
            ),
          if (others > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Text('$others more for other engines', style: ui(TypeSize.small, color: Pal.text3)),
            ),
          ListRow(
            key: const Key('preset-save-as'),
            label: '+ Save as…',
            ghost: true,
            tooltip: 'Save the sound as it is now on the Striso, with a title and a description',
            onTap: () => saveBoardPresetAs(context, ctl),
          ),
          ListRow(
            key: const Key('preset-install'),
            label: 'Install…',
            ghost: true,
            tooltip: 'Install preset files (.json) on the Striso; or drop them on the window',
            onTap: () => installPresetFiles(ctl),
          ),
        ],
      ],
    );
  }
}

/// Load, Share…, Delete for one of the board's presets (a factory one: Load and Share…).
List<PopupMenuEntry<void>> boardPresetMenu(BuildContext context, AppController ctl, BoardPreset p) {
  PopupMenuItem<void> item(String label, VoidCallback f, {Color color = Pal.text1}) => PopupMenuItem<void>(
    height: Sizes.row,
    onTap: f,
    child: Text(label, style: ui(TypeSize.body, color: color)),
  );
  return [
    item('Load', () => ctl.openBoardPreset(p)),
    item('Share…', () => sharePresetFile(ctl, p)),
    if (!p.factory) item('Delete', () => confirmDeletePreset(context, ctl, p), color: Pal.error),
  ];
}

/// A file name from a title: what Windows and macOS take.
String presetFileName(BoardPreset p) {
  final t = p.title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  return '${t.isEmpty ? 'preset ${p.id}' : t}.preset.json';
}

Future<void> sharePresetFile(AppController ctl, BoardPreset p) async {
  final loc = await getSaveLocation(
    suggestedName: presetFileName(p),
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Striso preset', extensions: ['json']),
    ],
  );
  if (loc == null) return;
  await ctl.sharePreset(p, loc.path);
}

Future<void> installPresetFiles(AppController ctl) async {
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Striso preset', extensions: ['json']),
    ],
  );
  for (final f in files) {
    await ctl.installPresetFile(f.path);
  }
}

Future<void> confirmDeletePreset(BuildContext context, AppController ctl, BoardPreset p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StrisoDialog(
      title: 'Delete "${p.title}" from the Striso?',
      maxWidth: 420,
      body: Text('It is gone from the board. Share it first to keep a copy.', style: ui(TypeSize.body, color: Pal.text2)),
      actions: [
        Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx, false)),
        Btn('Delete', key: const Key('preset-delete-confirm'), kind: BtnKind.danger, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  if (ok == true) await ctl.deleteBoardPreset(p);
}

/// Save as…: a title and a description; the board saves the current voice as a preset.
Future<void> saveBoardPresetAs(BuildContext context, AppController ctl) async {
  if (!ctl.connected || ctl.voiceName.isEmpty) {
    ctl.toast('Connect first: a preset is saved on the board', 'warn');
    return;
  }
  final title = TextEditingController(text: ctl.voiceName.split(':').last);
  final desc = TextEditingController();
  String? problem;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void check() => setState(() => problem = AppController.presetFieldsProblem(title.text, desc.text));
        return StrisoDialog(
          title: 'Save as a preset on the Striso',
          maxWidth: 460,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InputField(
                key: const Key('preset-title'),
                controller: title,
                hint: 'Title',
                autofocus: true,
                maxLength: presetMaxTitle,
                onChanged: (_) => check(),
              ),
              const SizedBox(height: Space.s),
              InputField(
                key: const Key('preset-description'),
                controller: desc,
                hint: 'Description (optional)',
                maxLength: presetMaxDescription,
                onChanged: (_) => check(),
              ),
              const SizedBox(height: Space.s),
              Text(
                problem ?? 'The board saves ${engineInfo(ctl.currentEngine).label} as it sounds now, every parameter by name.',
                style: ui(TypeSize.small, color: problem != null ? Pal.error : Pal.text3),
              ),
            ],
          ),
          actions: [
            Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx, false)),
            Btn(
              'Save',
              key: const Key('preset-save'),
              kind: BtnKind.primary,
              onPressed: AppController.presetFieldsProblem(title.text, desc.text) == null ? () => Navigator.pop(ctx, true) : null,
            ),
          ],
        );
      },
    ),
  );
  // (the controllers are not disposed here: the dialog still fades out with them)
  final t = title.text, d = desc.text;
  if (ok == true) await ctl.savePresetAs(t, d);
}

/// Preset files dropped on the window are installed on the Striso.
class PresetDropTarget extends StatefulWidget {
  final AppController ctl;
  final Widget child;
  const PresetDropTarget(this.ctl, {super.key, required this.child});
  @override
  State<PresetDropTarget> createState() => _PresetDropTargetState();
}

class _PresetDropTargetState extends State<PresetDropTarget> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) async {
        setState(() => _over = false);
        final files = d.files.map((f) => f.path).where((p) => p.toLowerCase().endsWith('.json')).toList();
        if (files.isEmpty) {
          widget.ctl.toast('Drop preset files (.json) to install them on the Striso', 'warn');
          return;
        }
        for (final f in files) {
          if (File(f).existsSync()) await widget.ctl.installPresetFile(f);
        }
      },
      child: Stack(
        children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Pal.bg0.withValues(alpha: 0.72),
                  alignment: Alignment.center,
                  child: Text('Drop preset files to install them on the Striso', style: ui(TypeSize.title, color: Pal.text1)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
