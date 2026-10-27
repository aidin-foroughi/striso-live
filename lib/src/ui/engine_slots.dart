// The engine slots of the board that plays, the Striso's or Virtual's (research/
// board_engine_modules.md 4.3): what its firmware lists in each slot (Stco), the engine library's
// packages to put on it (Stci, with the firmware's progress), an erase per slot (Stcz) and Add an
// engine… for a package from elsewhere. Everything shown is what the firmware said.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../engine_library.dart' show packageExt;
import '../theme.dart';
import 'chrome.dart';

class EngineSlots extends StatelessWidget {
  final AppController ctl;
  const EngineSlots(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final slots = ctl.moduleSlots, note = ctl.moduleNote, target = ctl.slotTarget;
    final library = ctl.engineLibrary();
    final busy = ctl.modulesBusy || ctl.saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Micro(ctl.connected ? 'Engines on $target' : 'Engines'),
        const SizedBox(height: Space.xs),
        if (!ctl.connected)
          Text('Connect the Striso or play Virtual to see its engine slots.', style: ui(TypeSize.body, color: Pal.text2))
        else if (slots == null)
          Text('This firmware has no engine slots.', key: const Key('slots-none'), style: ui(TypeSize.body, color: Pal.text2))
        else
          for (final s in slots) _SlotRow(ctl, s, busy: busy),
        ValueListenableBuilder<ModuleUpload?>(
          valueListenable: ctl.moduleUpload,
          builder: (context, u, _) => u == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: Space.s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Putting ${u.name} on $target · ${u.bytes ~/ 1024} of ${(u.total + 1023) ~/ 1024} KB',
                        key: const Key('slots-progress'),
                        style: ui(TypeSize.small, color: Pal.text2),
                      ),
                      const SizedBox(height: Space.xs),
                      SizedBox(
                        width: 200,
                        child: LinearProgressIndicator(
                          value: u.total > 0 ? u.bytes / u.total : null,
                          minHeight: 2,
                          color: Pal.accent,
                          backgroundColor: Pal.bg3,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: SelectableText(note.text, key: const Key('slots-note'), style: ui(TypeSize.small, color: note.error ? Pal.error : Pal.text2)),
          ),
        if (slots != null && library.isNotEmpty) ...[
          const SizedBox(height: Space.m),
          const Micro('Engine library'),
          const SizedBox(height: Space.xs),
          for (final p in library)
            SizedBox(
              height: Sizes.row,
              child: Row(
                children: [
                  Expanded(
                    child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.body)),
                  ),
                  Btn(
                    'Put on $target',
                    key: Key('put-${p.name}'),
                    kind: BtnKind.ghost,
                    tooltip: 'Sends the package to $target; its firmware checks it and keeps it in a free slot',
                    onPressed: busy ? null : () => ctl.putEngine(p.path),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: Space.s),
        Btn(
          'Add an engine…',
          key: const Key('slots-add'),
          kind: BtnKind.ghost,
          tooltip: ctl.engineDir == null ? 'There is no engine folder in this run' : 'An engine package (.$packageExt), or a zip of them, into the library and onto the board that plays',
          onPressed: busy || ctl.engineDir == null ? null : () => _add(ctl),
        ),
      ],
    );
  }

  Future<void> _add(AppController ctl) async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Engine package', extensions: [packageExt, 'zip']),
      ],
    );
    if (f != null) await ctl.installAndAddEngine(f.path);
  }
}

class _SlotRow extends StatelessWidget {
  final AppController ctl;
  final ModuleSlot s;
  final bool busy;
  const _SlotRow(this.ctl, this.s, {required this.busy});

  @override
  Widget build(BuildContext context) {
    final (String name, String right, Color colour) = switch (s.state) {
      SlotState.empty => ('empty', '', Pal.text3),
      SlotState.partial => ('an install that did not finish', '', Pal.text3),
      SlotState.ok => ('${s.id} ${s.version}', s.bytes == null ? '' : '${(s.bytes! + 1023) ~/ 1024} KB', Pal.text1),
      SlotState.disabled => (s.id == null ? 'unreadable' : '${s.id} ${s.version}', 'disabled: ${s.reason}', Pal.text3),
    };
    return SizedBox(
      height: Sizes.row,
      child: Row(
        children: [
          SizedBox(width: 52, child: Text('slot ${s.slot}', style: ui(TypeSize.small, color: Pal.text3))),
          Expanded(
            child: Text(name, key: Key('slot-${s.slot}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.body, color: colour)),
          ),
          if (right.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Tooltip(
                message: right,
                child: Text(
                  right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(TypeSize.small, color: s.state == SlotState.disabled ? Pal.error : Pal.text3),
                ),
              ),
            ),
          if (s.state != SlotState.empty)
            IconBtn(
              Icons.delete_outline,
              key: Key('erase-${s.slot}'),
              tooltip: 'Erase slot ${s.slot}',
              onPressed: busy ? null : () => _erase(context),
            ),
        ],
      ),
    );
  }

  Future<void> _erase(BuildContext context) async {
    final what = s.id ?? 'what is in it';
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => StrisoDialog(
        title: 'Erase slot ${s.slot}?',
        body: Text(
          ctl.caps?.restarts == true
              ? '${_cap(ctl.slotTarget)} forgets $what and starts again without it. The package stays in the engine library.'
              : '${_cap(ctl.slotTarget)} forgets $what; it is gone once ${ctl.slotTarget} starts again. The package stays in the engine library.',
          style: ui(TypeSize.body, color: Pal.text2),
        ),
        actions: [
          Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx, false)),
          Btn('Erase', key: const Key('dlg-erase-go'), kind: BtnKind.danger, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (r == true) await ctl.eraseSlot(s.slot);
  }
}

/// [s] with its first letter upper case ("the Striso" -> "The Striso").
String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
