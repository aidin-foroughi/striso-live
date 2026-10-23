// Sound (DESIGN.md 3): the top row (name, undo/redo, Reset, Mutate, A/B, Save sound, more), the
// voice parameters in groups, the effects column with each effect's switch in its label row,
// My sounds, and the morph tool at the bottom. Below 1200 px everything stacks.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'knobs.dart';
import 'morph.dart';
import 'play_tab.dart';

class SoundTab extends StatelessWidget {
  final AppController ctl;
  const SoundTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 1200;
        final voice = VoiceRack(ctl);
        final side = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FxColumn(ctl),
            const SizedBox(height: Space.xl),
            MySounds(ctl),
          ],
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SoundTopRow(ctl),
              const SizedBox(height: Space.s),
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: SingleChildScrollView(child: voice)),
                          const SizedBox(width: Space.column),
                          SizedBox(
                            width: Sizes.fxColumn,
                            child: SingleChildScrollView(child: side),
                          ),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            voice,
                            const SizedBox(height: Space.xl),
                            side,
                          ],
                        ),
                      ),
              ),
              MorphTool(ctl),
            ],
          ),
        );
      },
    );
  }
}

class SoundTopRow extends StatelessWidget {
  final AppController ctl;
  const SoundTopRow(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl, ctl.values]),
      builder: (context, _) {
        final any = ctl.hasSound;
        final edited = any && ctl.edited;
        return SizedBox(
          height: Sizes.header,
          child: Row(
            children: [
              Flexible(child: SoundName(ctl)),
              const SizedBox(width: Space.xl),
              IconBtn(Icons.undo, key: const Key('btn-undo'), tooltip: 'Undo (Ctrl+Z)', onPressed: ctl.history.canUndo ? ctl.undo : null),
              IconBtn(Icons.redo, key: const Key('btn-redo'), tooltip: 'Redo (Ctrl+Y)', onPressed: ctl.history.canRedo ? ctl.redo : null),
              const SizedBox(width: Space.s),
              Btn(
                'Reset',
                kind: BtnKind.ghost,
                tooltip: edited ? 'Back to the values read from the board' : 'Nothing edited',
                onPressed: edited ? ctl.resetAll : null,
              ),
              const SizedBox(width: Space.xs),
              Btn(
                'Mutate',
                key: const Key('btn-mutate'),
                tooltip: any ? 'Small random changes within the ranges (M). Alt+click a knob to lock it.' : 'Connect first',
                onPressed: any ? ctl.mutate : null,
              ),
              _MutateMenu(ctl),
              const SizedBox(width: Space.xs),
              _ABButton(ctl),
              const SizedBox(width: Space.s),
              Btn(
                'Save sound',
                key: const Key('btn-save-sound'),
                kind: edited ? BtnKind.primary : BtnKind.secondary,
                tooltip: 'Save the sound under a name (Ctrl+S)',
                onPressed: any ? () => saveSoundAs(context, ctl) : null,
              ),
              const Spacer(),
              PopupMenuButton<void>(
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz, size: 18, color: Pal.text2),
                itemBuilder: (context) => [
                  PopupMenuItem<void>(
                    height: Sizes.row,
                    enabled: any && ctl.voiceName.isNotEmpty,
                    onTap: () => showCode(context, ctl, ctl.currentAsPreset()),
                    child: Text('Copy as C', style: ui(TypeSize.body)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MutateMenu extends StatelessWidget {
  final AppController ctl;
  const _MutateMenu(this.ctl);

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'What and how much Mutate changes',
      icon: const Icon(Icons.expand_more, size: 16, color: Pal.text3),
      padding: EdgeInsets.zero,
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 240,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Micro('Scope'),
                  const SizedBox(height: Space.xs),
                  Seg<String>(
                    value: ctl.mutateScope,
                    items: const [('0', 'Voice', null), ('1', 'Effects', null), ('both', 'Both', null)],
                    onChanged: (v) => setState(() => ctl.setMutateScope(v)),
                  ),
                  const SizedBox(height: Space.m),
                  Micro('Amount ${(ctl.mutateAmount * 100).round()}%'),
                  Slider(value: ctl.mutateAmount, min: 0.02, max: 0.5, onChanged: (v) => setState(() => ctl.mutateAmount = v)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A/B: hold for the preset's values, release for the edits; a click toggles.
class _ABButton extends StatelessWidget {
  final AppController ctl;
  const _ABButton(this.ctl);

  @override
  Widget build(BuildContext context) {
    final on = ctl.abOn;
    return Tooltip(
      message: on
          ? 'Hearing A, the preset as loaded. Click again for B, your edits.'
          : 'A/B: hold (or press B) to hear the preset as loaded; click toggles',
      child: GestureDetector(
        onLongPressStart: (_) => ctl.setAB(true),
        onLongPressEnd: (_) => ctl.setAB(false),
        child: Btn(
          on ? 'A' : 'A/B',
          key: const Key('btn-ab'),
          kind: BtnKind.ghost,
          pressed: on,
          onPressed: ctl.hasSound ? () => ctl.setAB(!on) : null,
        ),
      ),
    );
  }
}

/// Voice parameters: groups in firmware order, a micro label then knobs in a flowing row; on/off
/// parameters as inline toggles.
class VoiceRack extends StatelessWidget {
  final AppController ctl;
  const VoiceRack(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final v = ctl.params[0]!;
        if (v.params.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: EmptyNote(
              ctl.connected && ctl.listsLoading
                  ? 'Reading the parameters from the board…'
                  : !ctl.connected
                  ? "Connect to see this voice's parameters."
                  : v.missing
                  ? 'The board did not list parameters (firmware without live parameters?).'
                  : 'This voice has no live parameters yet.',
            ),
          );
        }
        final groups = <String, List<Param>>{};
        for (final p in v.params) {
          (groups[p.group] ??= []).add(p);
        }
        return Wrap(
          spacing: Space.xl,
          runSpacing: Space.l,
          children: [
            for (final MapEntry(key: name, value: ps) in groups.entries)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Micro(prettyName(name)),
                  const SizedBox(height: Space.s),
                  Wrap(
                    spacing: Space.s,
                    runSpacing: Space.s,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [for (final p in ps) p.kind == Kind.onOff ? ToggleCtl(ctl: ctl, target: 0, p: p) : Knob(ctl: ctl, target: 0, p: p)],
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Effects: one group per effect, its switch in the label row; an off effect's knobs at 40%.
class FxColumn extends StatelessWidget {
  final AppController ctl;
  const FxColumn(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final f = ctl.params[1]!;
        if (f.params.isEmpty) {
          return EmptyNote(
            !ctl.connected
                ? 'Connect to see the master effects.'
                : f.missing
                ? 'The board did not list effect parameters.'
                : 'The master effects have no live parameters yet.',
          );
        }
        final groups = <String, List<Param>>{};
        for (final p in f.params) {
          (groups[p.group] ??= []).add(p);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final MapEntry(key: name, value: ps) in groups.entries) ...[
              Wrap(
                spacing: Space.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Micro(prettyName(name)),
                  for (final sw in ps.where((p) => p.kind == Kind.onOff))
                    ToggleCtl(ctl: ctl, target: 1, p: sw, showName: ps.where((p) => p.kind == Kind.onOff).length > 1),
                ],
              ),
              const SizedBox(height: Space.s),
              Wrap(
                spacing: Space.s,
                runSpacing: Space.s,
                children: [
                  for (final p in ps.where((p) => p.kind != Kind.onOff))
                    Knob(ctl: ctl, target: 1, p: p, enable: ps.where((q) => q.kind == Kind.onOff).firstOrNull),
                ],
              ),
              const SizedBox(height: Space.l),
            ],
          ],
        );
      },
    );
  }
}

/// My sounds: all, or the current engine's; rows with the engine dot and a menu; Import and Export.
class MySounds extends StatefulWidget {
  final AppController ctl;
  const MySounds(this.ctl, {super.key});
  @override
  State<MySounds> createState() => _MySoundsState();
}

class _MySoundsState extends State<MySounds> {
  bool all = true;

  Future<void> _export() async {
    final ctl = widget.ctl;
    if (ctl.presets.isEmpty) {
      ctl.toast('No saved sounds to export yet', 'warn');
      return;
    }
    final day = DateTime.now().toIso8601String().substring(0, 10);
    try {
      final loc = await getSaveLocation(
        suggestedName: 'striso-sounds-$day.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (loc == null) return;
      await File(loc.path).writeAsString(ctl.exportPresets());
      ctl.toast('Exported ${ctl.presets.length} sounds');
    } catch (e) {
      ctl.toast('Export failed: $e', 'error');
    }
  }

  Future<void> _import() async {
    final ctl = widget.ctl;
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (f == null) return;
      ctl.importPresets(await f.readAsString());
    } catch (e) {
      ctl.toast('Import failed: $e', 'error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctl = widget.ctl;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final engine = ctl.currentEngine;
        final list = all || engine.isEmpty ? ctl.presets : ctl.presets.where((p) => p.engine == engine).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.l,
              children: [
                const Micro('My sounds'),
                Seg<bool>(
                  value: all,
                  onChanged: (v) => setState(() => all = v),
                  items: [
                    (true, 'all', 'Every saved sound'),
                    (false, engine.isEmpty ? 'engine' : engineInfo(engine).label.toLowerCase(), 'This engine only'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: Space.xs),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Text('Sounds you save appear here.', style: ui(TypeSize.body, color: Pal.text2)),
              ),
            for (final p in list)
              ListRow(
                label: p.name,
                current: ctl.lastSound == p.name,
                edited: ctl.lastSound == p.name && ctl.edited,
                dot: engineColor(p.engine),
                dotAlways: true,
                tooltip: 'Recall "${p.name}" (${p.voice})',
                onTap: () => ctl.recallPreset(p),
                menu: (context) => soundMenu(context, ctl, p),
              ),
            const SizedBox(height: Space.s),
            Row(
              children: [
                Btn('Import', kind: BtnKind.ghost, onPressed: _import),
                Btn('Export all', kind: BtnKind.ghost, onPressed: _export),
              ],
            ),
          ],
        );
      },
    );
  }
}
