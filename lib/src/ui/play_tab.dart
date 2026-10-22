// Play: the engines and their presets (and your sounds for them) on the left, the board with the
// chord, key and progression in the middle, the main knobs of the voice on the right.

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'board_view.dart';
import 'live_panel.dart';
import 'sound_panel.dart';

class PlayTab extends StatelessWidget {
  final AppController ctl;
  const PlayTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= Sizes.wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: Sizes.leftColumn, child: EnginePanel(ctl)),
              const VerticalDivider(width: 1, thickness: 1, color: Pal.seam),
              Expanded(child: BoardColumn(ctl)),
              const VerticalDivider(width: 1, thickness: 1, color: Pal.seam),
              SizedBox(width: Sizes.rightColumn, child: MainKnobs(ctl)),
            ],
          );
        }
        // narrow: the board first, then the voices and the knobs, all in one scroll
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: (c.maxWidth / 1.15).clamp(360.0, 640.0) + 240, child: BoardColumn(ctl)),
              const Divider(height: 1, thickness: 1, color: Pal.seam),
              EnginePanel(ctl, scroll: false),
              const Divider(height: 1, thickness: 1, color: Pal.seam),
              MainKnobs(ctl, scroll: false),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// engines and presets

class EnginePanel extends StatelessWidget {
  final AppController ctl;
  final bool scroll;
  const EnginePanel(this.ctl, {super.key, this.scroll = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final engines = ctl.engines();
        final cur = ctl.currentEngine;
        final info = engineInfo(cur);
        final list = ctl.voices.where((v) => v.engine == cur).toList();
        final mine = ctl.presets.where((p) => p.engine == cur).toList();
        final body = <Widget>[
          if (!ctl.connected)
            Padding(
              padding: const EdgeInsets.only(top: Space.m),
              child: Text('Voices and presets appear here once the Striso is connected.', style: ui(TypeSize.label, color: Pal.faint)),
            )
          else if (ctl.voices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.m),
              child: Text('This firmware has no voice list (a single voice build).', style: ui(TypeSize.label, color: Pal.faint)),
            )
          else ...[
            const SizedBox(height: Space.l),
            Text(info.label, style: ui(TypeSize.title + 2, weight: FontWeight.w600)),
            if (info.blurb.isNotEmpty) Text(info.blurb, style: ui(TypeSize.caption, color: Pal.faint)),
            const SizedBox(height: Space.s),
            for (final v in list)
              _PresetRow(
                key: Key('preset-${v.index}'),
                label: v.preset ?? info.label,
                trailing: '${v.index}',
                current: v.index == ctl.current,
                pending: v.index == ctl.pendingVoice,
                tooltip: '${v.name} (voice ${v.index})',
                onTap: () => ctl.selectVoice(v.index),
              ),
            const SizedBox(height: Space.l),
            Text('My sounds', style: ui(TypeSize.label, weight: FontWeight.w600)),
            const SizedBox(height: Space.xs),
            if (mine.isEmpty)
              Text('Sounds you save for ${info.label} show here (Sound tab, My sounds).', style: ui(TypeSize.caption, color: Pal.faint))
            else
              for (final p in mine)
                _PresetRow(
                  label: p.name,
                  trailing: p.voice.contains(':') ? p.voice.split(':').last : '',
                  current: ctl.lastSound == p.name,
                  tooltip: 'Recall "${p.name}" (${p.voice})',
                  onTap: () => ctl.recallPreset(p),
                  mine: true,
                ),
          ],
        ];
        final content = Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, 0),
              child: Row(
                children: [
                  Text('Voices', style: ui(TypeSize.title, weight: FontWeight.w600)),
                  const Spacer(),
                  Btn('Refresh', kind: BtnKind.quiet, small: true, tooltip: 'Read the voice list again', onPressed: ctl.connected ? ctl.syncVoice : null),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, 0),
              child: Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [for (final e in engines) EngineDot(e: e, on: e.engine == cur, onTap: () => ctl.selectEngine(e.engine))],
              ),
            ),
            if (scroll) Expanded(child: SingleChildScrollView(child: content)) else content,
          ],
        );
      },
    );
  }
}

/// An engine button in its voice key's led colour, like the row of voice keys on the Striso.
class EngineDot extends StatefulWidget {
  final EngineButton e;
  final bool on;
  final VoidCallback onTap;
  const EngineDot({super.key, required this.e, required this.on, required this.onTap});
  @override
  State<EngineDot> createState() => _EngineDotState();
}

const _engineShort = {'strisy': 'St', 'va': 'VA', 'modal': 'Mo', 'bowed': 'Bo', 'wind': 'Wi', 'ep': 'EP', 'brass': 'Br', 'reed': 'Re', 'sine': 'Si'};

class _EngineDotState extends State<EngineDot> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final col = rgb(e.color);
    final has = e.count > 0;
    final info = engineInfo(e.engine);
    final short = _engineShort[e.engine] ?? (e.engine.length > 2 ? e.engine.substring(0, 2) : e.engine);
    return Tooltip(
      message: has ? '${info.label}: ${e.count} preset${e.count == 1 ? '' : 's'}' : '${info.label}: not in this firmware',
      child: MouseRegion(
        cursor: has ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: Key('engine-${e.engine}'),
          onTap: has ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Timing.fast,
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.on ? col : col.withValues(alpha: has ? (_hover ? 0.28 : 0.14) : 0.05),
              border: Border.all(color: has ? col : col.withValues(alpha: 0.3), width: widget.on ? 2 : 1.2),
              boxShadow: widget.on ? [BoxShadow(color: col.withValues(alpha: 0.55), blurRadius: 12)] : null,
            ),
            child: Text(
              short,
              style: ui(TypeSize.caption, weight: FontWeight.w600, color: widget.on ? Pal.ink : (has ? Pal.text : Pal.faint)),
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetRow extends StatefulWidget {
  final String label, trailing, tooltip;
  final bool current, pending, mine;
  final VoidCallback onTap;
  const _PresetRow({
    super.key,
    required this.label,
    required this.trailing,
    required this.current,
    required this.tooltip,
    required this.onTap,
    this.pending = false,
    this.mine = false,
  });
  @override
  State<_PresetRow> createState() => _PresetRowState();
}

class _PresetRowState extends State<_PresetRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 900),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Timing.fast,
            margin: const EdgeInsets.only(bottom: Space.xxs),
            padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
            decoration: BoxDecoration(
              color: cur ? Pal.honeyDim : (_hover ? Pal.panel2 : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.small),
              border: Border.all(color: cur ? Pal.honey : Colors.transparent),
            ),
            child: Opacity(
              opacity: widget.pending ? 0.6 : 1,
              child: Row(
                children: [
                  if (widget.mine) ...[const Icon(Icons.bookmark_outline, size: 14, color: Pal.muted), const SizedBox(width: Space.s)],
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(TypeSize.body, color: cur ? Pal.honey : Pal.text, weight: cur ? FontWeight.w600 : FontWeight.w400),
                    ),
                  ),
                  Text(widget.trailing, style: ui(TypeSize.micro, color: Pal.faint)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// the board with its toolbar, chord readout and progression

class BoardColumn extends StatelessWidget {
  final AppController ctl;
  const BoardColumn(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayToolbar(ctl),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: BoardView(ctl)),
              Positioned.fill(child: InviteCard(ctl)),
            ],
          ),
        ),
        HarmonyReadout(ctl),
        Progression(ctl),
        ProbeLine(ctl),
      ],
    );
  }
}

class PlayToolbar extends StatelessWidget {
  final AppController ctl;
  const PlayToolbar(this.ctl, {super.key});

  static const _names = [
    (Names.octave, 'Labels: D4'),
    (Names.letters, 'Labels: D'),
    (Names.degrees, 'Labels: 1 2 3'),
    (Names.solfege, 'Labels: do re'),
    (Names.off, 'Labels: none'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.xs),
        child: Row(
          children: [
            Expanded(child: LiveStats(ctl)),
            SmallSelect<int>(
              width: 62,
              value: ctl.keyRoot,
              items: ctl.rootChoices,
              onChanged: ctl.keyScale == 'off' ? null : (v) => ctl.setKey(root: v),
            ),
            const SizedBox(width: Space.xs),
            SmallSelect<String>(
              key: const Key('key-scale'),
              value: ctl.keyScale,
              items: [for (final id in scaleOrder) (id, id == 'off' ? 'No key' : scales[id]!.label)],
              onChanged: (v) => ctl.setKey(scale: v),
            ),
            const SizedBox(width: Space.s),
            Tooltip(
              message: 'Key labels: note names with octave, note names, scale degrees or solfège (with a key), or none',
              waitDuration: const Duration(milliseconds: 900),
              child: SmallSelect<Names>(key: const Key('names'), value: ctl.names, items: _names, onChanged: ctl.setNames),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keys down, messages per second (and a silent stream), the transposition.
class LiveStats extends StatelessWidget {
  final AppController ctl;
  const LiveStats(this.ctl, {super.key});

  Widget _stat(String b, String rest, {Color? color}) => Text.rich(
    TextSpan(
      style: ui(TypeSize.small, color: color ?? Pal.muted),
      children: [
        TextSpan(text: b, style: ui(TypeSize.small, color: color ?? Pal.text, weight: FontWeight.w600)),
        TextSpan(text: rest),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.stats,
      builder: (context, _) {
        final t = ctl.live.transpose;
        final stalled = ctl.streamStalled;
        return Wrap(
          spacing: Space.l,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _stat('${ctl.live.activeCount()}', ' keys down'),
            Tooltip(
              message: ctl.diagnosticsText().split('  |  ').join('\n'),
              child: _stat('${ctl.live.rate.round()}', stalled ? ' messages/s (stream silent)' : ' messages/s', color: stalled ? Pal.honey : null),
            ),
            if (t != 0)
              Tooltip(
                message: 'Transposition guessed from the octave buttons. Click to reset to D4 in the middle.',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: ctl.resetTranspose,
                    child: Text(
                      'Transposed ${t > 0 ? '+' : '−'}${t.abs() % 12 == 0 ? '${t.abs() ~/ 12} oct' : '${t.abs()} st'}',
                      style: ui(TypeSize.small, color: Pal.honey),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// the main knobs

class MainKnobs extends StatelessWidget {
  final AppController ctl;
  final bool scroll;
  const MainKnobs(this.ctl, {super.key, this.scroll = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final knobs = ctl.mainKnobs();
        final fx = ctl.mainFx();
        Widget grid(List<Param> ps, int t, Color accent) => Wrap(
          spacing: Space.xs,
          runSpacing: Space.s,
          children: [
            for (final p in ps)
              p.kind == Kind.onOff
                  ? ToggleCtl(ctl: ctl, target: t, p: p, accent: accent, accentDim: accent.withValues(alpha: 0.16))
                  : Knob(ctl: ctl, target: t, p: p, accent: accent),
          ],
        );
        final body = Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (knobs.isEmpty && fx.isEmpty)
                Text(
                  !ctl.connected
                      ? 'The main knobs of the voice show here once the Striso is connected.'
                      : ctl.listsLoading
                      ? 'Reading the parameters from the board…'
                      : 'This voice has no live parameters.',
                  style: ui(TypeSize.label, color: Pal.faint),
                ),
              if (knobs.isNotEmpty) ...[
                const SizedBox(height: Space.m),
                Text('Voice', style: ui(TypeSize.small, color: Pal.honey)),
                const SizedBox(height: Space.xs),
                grid(knobs, 0, Pal.honey),
              ],
              if (fx.isNotEmpty) ...[
                const SizedBox(height: Space.l),
                Text('Effects', style: ui(TypeSize.small, color: Pal.glacier)),
                const SizedBox(height: Space.xs),
                grid(fx, 1, Pal.glacier),
              ],
              if (ctl.hasSound) ...[
                const SizedBox(height: Space.l),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Btn(
                    'All ${ctl.params[0]!.params.length + ctl.params[1]!.params.length} parameters',
                    key: const Key('to-sound'),
                    small: true,
                    kind: BtnKind.quiet,
                    tooltip: 'The full racks, mutate, morph and your sounds',
                    onPressed: () => ctl.setTab(AppTab.sound),
                  ),
                ),
              ],
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, 0),
              child: Row(
                children: [
                  Text('Sound', style: ui(TypeSize.title, weight: FontWeight.w600)),
                  const Spacer(),
                  Btn('Undo', small: true, kind: BtnKind.quiet, tooltip: 'Undo (Ctrl+Z)', onPressed: ctl.history.canUndo ? ctl.undo : null),
                  Btn('Redo', small: true, kind: BtnKind.quiet, tooltip: 'Redo (Ctrl+Shift+Z)', onPressed: ctl.history.canRedo ? ctl.redo : null),
                ],
              ),
            ),
            if (scroll) Expanded(child: SingleChildScrollView(child: body)) else body,
          ],
        );
      },
    );
  }
}
