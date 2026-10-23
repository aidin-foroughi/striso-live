// Play (DESIGN.md 3): engines and this engine's presets plus your sounds on the left; the board
// with its toolbar and the harmony strip in the middle; the sound name, hero knobs and the
// reverb/delay amounts on the right. 1000-1279 px: a narrower left column and the knobs as a
// strip between board and harmony.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'board_view.dart';
import 'chrome.dart';
import 'knobs.dart';
import 'live_panel.dart';
import 'scale_picker.dart';

class PlayTab extends StatelessWidget {
  final AppController ctl;
  const PlayTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        if (w >= 1280) {
          final right = w >= 1480 ? Sizes.right : Sizes.rightNarrow;
          return Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: Sizes.left, child: EnginePanel(ctl)),
                const SizedBox(width: Space.column),
                Expanded(child: BoardColumn(ctl)),
                const SizedBox(width: Space.column),
                SizedBox(
                  width: right,
                  child: HeroPanel(ctl, knobSize: w >= 1480 ? Sizes.knobHero : 48),
                ),
              ],
            ),
          );
        }
        if (w >= Sizes.minWidth) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: Sizes.leftNarrow, child: EnginePanel(ctl, buttonSize: 20)),
                const SizedBox(width: Space.column),
                Expanded(child: BoardColumn(ctl, strip: true)),
              ],
            ),
          );
        }
        // under the minimum window size: one scroll
        return SingleChildScrollView(
          padding: const EdgeInsets.all(Space.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: (w / 1.15).clamp(360.0, 640.0) + Sizes.toolbar + Sizes.harmony + 60, child: BoardColumn(ctl, strip: true)),
              const SizedBox(height: Space.xl),
              EnginePanel(ctl, scroll: false),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// engines, presets and my sounds

class EnginePanel extends StatelessWidget {
  final AppController ctl;
  final bool scroll;
  final double buttonSize;
  const EnginePanel(this.ctl, {super.key, this.scroll = true, this.buttonSize = 24});

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
        final col = engineColor(cur);
        final body = <Widget>[
          if (!ctl.connected)
            const Padding(
              padding: EdgeInsets.only(top: Space.l),
              child: EmptyNote('Voices and presets appear here once the Striso is connected.'),
            )
          else if (ctl.voices.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: Space.l),
              child: EmptyNote('This firmware has no voice list (a single voice build).'),
            )
          else ...[
            const SizedBox(height: Space.l),
            Row(
              children: [
                Expanded(
                  child: Text(info.label, style: ui(TypeSize.title, weight: FontWeight.w600)),
                ),
                SizedBox(
                  width: Sizes.control,
                  height: Sizes.control,
                  child: PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_horiz, size: 16, color: Pal.text3),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    constraints: const BoxConstraints(minWidth: 160),
                    onSelected: (v) => v == 'refresh' ? ctl.syncVoice() : null,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'refresh',
                        enabled: ctl.connected,
                        height: Sizes.row,
                        child: Text('Read the voice list again', style: ui(TypeSize.body)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (info.blurb.isNotEmpty) Text(info.blurb, style: ui(TypeSize.small, color: Pal.text3)),
            const SizedBox(height: Space.s),
            for (final v in list)
              ListRow(
                key: Key('preset-${v.index}'),
                label: v.preset ?? info.label,
                current: v.index == ctl.current,
                pending: v.index == ctl.pendingVoice,
                dot: col,
                tooltip: '${v.name} (voice ${v.index})',
                onTap: () => ctl.selectVoice(v.index),
              ),
            const SizedBox(height: Space.xl),
            const Micro('My sounds'),
            const SizedBox(height: Space.xs),
            if (mine.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Text('Sounds you save appear here.', style: ui(TypeSize.body, color: Pal.text2)),
              ),
            for (final p in mine)
              ListRow(
                label: p.name,
                current: ctl.lastSound == p.name,
                edited: ctl.lastSound == p.name && ctl.edited,
                dot: col,
                tooltip: 'Recall "${p.name}" (${p.voice})',
                onTap: () => ctl.recallPreset(p),
                menu: (context) => soundMenu(context, ctl, p),
              ),
            ListRow(label: '+ Save current', ghost: true, tooltip: 'Save the sound as it is now (Ctrl+S)', onTap: () => saveSoundAs(context, ctl)),
          ],
        ];
        final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: Sizes.toolbar,
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: buttonSize < 24 ? Space.xs : Space.s - 2,
                      runSpacing: Space.xs,
                      children: [
                        for (final (i, e) in engines.indexed)
                          EngineDot(
                            e: e,
                            on: e.engine == cur && ctl.connected,
                            size: buttonSize,
                            number: i < 7 ? i + 1 : null,
                            onTap: () => ctl.selectEngine(e.engine),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (scroll) Expanded(child: SingleChildScrollView(child: content)) else content,
          ],
        );
      },
    );
  }
}

/// Save the current sound under a name.
Future<void> saveSoundAs(BuildContext context, AppController ctl) async {
  if (!ctl.connected || ctl.voiceName.isEmpty) {
    ctl.toast('Connect first: a sound is saved from the board', 'warn');
    return;
  }
  final name = await askName(context, title: 'Save the sound', initial: ctl.lastSound ?? '${ctl.voiceName.split(':').last} ');
  if (name != null) ctl.saveCurrent(name);
}

/// Recall, Rename, Export, Delete for one of your sounds.
List<PopupMenuEntry<void>> soundMenu(BuildContext context, AppController ctl, Preset p) {
  PopupMenuItem<void> item(String label, VoidCallback f, {Color color = Pal.text1}) => PopupMenuItem<void>(
    height: Sizes.row,
    onTap: f,
    child: Text(label, style: ui(TypeSize.body, color: color)),
  );
  return [
    item('Recall', () => ctl.recallPreset(p)),
    item('Rename', () async {
      final n = await askName(context, title: 'Rename "${p.name}"', initial: p.name, action: 'Rename');
      if (n != null) ctl.renamePreset(p, n);
    }),
    item('Export', () async {
      try {
        final loc = await getSaveLocation(
          suggestedName: '${p.name.replaceAll(RegExp(r'[^\w\- ]'), '_')}.json',
          acceptedTypeGroups: const [
            XTypeGroup(label: 'JSON', extensions: ['json']),
          ],
        );
        if (loc == null) return;
        await File(loc.path).writeAsString(ctl.exportPreset(p));
        ctl.toast('Exported "${p.name}"');
      } catch (e) {
        ctl.toast('Export failed: $e', 'error');
      }
    }),
    item('Delete', () => ctl.deletePreset(p), color: Pal.error),
  ];
}

/// An engine button: a ring in the engine colour, filled when selected (strisy's grey disc gets
/// a dark centre dot); missing engines at 30%.
class EngineDot extends StatefulWidget {
  final EngineButton e;
  final bool on;
  final double size;
  final int? number;
  final VoidCallback onTap;
  const EngineDot({super.key, required this.e, required this.on, required this.onTap, this.size = 24, this.number});
  @override
  State<EngineDot> createState() => _EngineDotState();
}

class _EngineDotState extends State<EngineDot> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final col = engineColor(e.engine);
    final has = e.count > 0;
    final info = engineInfo(e.engine);
    return Tooltip(
      message: has
          ? '${info.label}${info.blurb.isNotEmpty ? ': ${info.blurb}' : ''} (${e.count} preset${e.count == 1 ? '' : 's'})${widget.number != null ? ' · key ${widget.number}' : ''}'
          : '${info.label}: not in this firmware',
      child: MouseRegion(
        cursor: has ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: Key('engine-${e.engine}'),
          onTap: has ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Timing.quick,
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.on ? col : Colors.transparent,
              border: Border.all(color: has ? col : col.withValues(alpha: 0.3), width: _hover && has && !widget.on ? 2 : 1.5),
            ),
            child: widget.on && e.engine == 'strisy' ? const Pip(Pal.accentInk, size: 6) : null,
          ),
        ),
      ),
    );
  }
}

/// A 28 px list row: body text2; current text1 500 with a 6 px dot; pending at 50% with a thin
/// bar; a `⋯` menu on hover; an accent dot when the recalled sound was edited since.
class ListRow extends StatefulWidget {
  final String label;
  final String? tooltip;
  final bool current, pending, ghost, edited, dotAlways;
  final Color? dot;
  final VoidCallback onTap;
  final List<PopupMenuEntry<void>> Function(BuildContext)? menu;
  const ListRow({
    super.key,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.current = false,
    this.pending = false,
    this.ghost = false,
    this.edited = false,
    this.dotAlways = false,
    this.dot,
    this.menu,
  });
  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    Widget row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Timing.quick,
          height: Sizes.row,
          padding: const EdgeInsets.only(left: Space.xs, right: Space.xs),
          decoration: BoxDecoration(color: _hover ? Pal.bg2 : Colors.transparent, borderRadius: BorderRadius.circular(Radii.small)),
          child: Stack(
            children: [
              Row(
                children: [
                  SizedBox(width: 14, child: (cur || widget.dotAlways) && widget.dot != null ? Center(child: Pip(widget.dot!)) : null),
                  Expanded(
                    child: Opacity(
                      opacity: widget.pending ? 0.5 : 1,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(
                          TypeSize.body,
                          color: widget.ghost ? (_hover ? Pal.text1 : Pal.text3) : (cur ? Pal.text1 : Pal.text2),
                          weight: cur ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  if (widget.edited)
                    const Padding(
                      padding: EdgeInsets.only(right: Space.xs),
                      child: Pip(Pal.accent, size: 5),
                    ),
                  if (widget.menu != null)
                    Opacity(
                      opacity: _hover ? 1 : 0,
                      child: PopupMenuButton<void>(
                        tooltip: 'More',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.more_horiz, size: 16, color: Pal.text2),
                        itemBuilder: widget.menu!,
                      ),
                    ),
                ],
              ),
              if (widget.pending)
                const Positioned(
                  left: 14,
                  right: 0,
                  bottom: 2,
                  child: SizedBox(
                    height: 1,
                    child: LinearProgressIndicator(minHeight: 1, color: Pal.accent, backgroundColor: Colors.transparent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip != null) row = Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 900), child: row);
    return row;
  }
}

// ---------------------------------------------------------------------------------------------
// the board with its toolbar and the harmony strip

class BoardColumn extends StatelessWidget {
  final AppController ctl;
  final bool strip;
  const BoardColumn(this.ctl, {super.key, this.strip = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayToolbar(ctl, showSound: strip),
        Expanded(child: BoardStage(ctl)),
        if (strip) KnobStrip(ctl),
        HarmonyStrip(ctl, compact: strip),
      ],
    );
  }
}

/// The board, dimmed while disconnected (45%) or saving (60%), with the inline invite.
class BoardStage extends StatelessWidget {
  final AppController ctl;
  final bool overlays;
  final double labelScale;
  const BoardStage(this.ctl, {super.key, this.overlays = false, this.labelScale = 1});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final opacity = ctl.saving ? 0.6 : (ctl.connected ? 1.0 : 0.45);
        return Stack(
          children: [
            Positioned.fill(
              child: AnimatedOpacity(
                duration: Timing.open,
                opacity: opacity,
                child: BoardView(ctl, overlays: overlays, labelScale: labelScale),
              ),
            ),
            if (!ctl.saving) Positioned.fill(child: InviteCard(ctl)),
          ],
        );
      },
    );
  }
}

class PlayToolbar extends StatelessWidget {
  final AppController ctl;
  final bool showSound;
  const PlayToolbar(this.ctl, {super.key, this.showSound = false});

  static const names = [
    (Names.octave, 'D4  note and octave'),
    (Names.letters, 'D  note'),
    (Names.degrees, '1 2 3  degrees'),
    (Names.solfege, 'do re  solfège'),
    (Names.pitch, 'Pitch  quarter tones, as the board plays'),
    (Names.cents, 'Cents  from 12-TET'),
    (Names.off, '—  no labels'),
  ];

  static const colours = [
    (KeyColour.off, 'Colour off'),
    (KeyColour.degree, 'Degree'),
    (KeyColour.function, 'Function'),
    (KeyColour.chord, 'Chord tones'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final t = ctl.live.transpose;
        return LayoutBuilder(
          builder: (context, c) {
            // the controls scroll inside their share when the toolbar is narrow (never overflow);
            // the legend goes first, under 900 px (DESIGN.md: narrower widths fold the extras)
            final wide = c.maxWidth >= 900;
            final controls = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KeyPicker(ctl),
                const SizedBox(width: Space.s),
                Tooltip(
                  message:
                      'Key labels: note names with octave, note names, scale degrees or solfège (with a key), '
                      'the pitch the board plays in quarter-tone notation, its cents from 12-TET, or none',
                  waitDuration: const Duration(milliseconds: 900),
                  child: SmallSelect<Names>(
                    key: const Key('names'),
                    value: ctl.names,
                    items: [for (final (n, l) in names) (n, l.split('  ').first)],
                    onChanged: ctl.setNames,
                  ),
                ),
                const SizedBox(width: Space.s),
                Tooltip(
                  message:
                      'Colour the keys by tonal function (rims only): each scale degree its own hue; tonic, '
                      'subdominant and dominant families; or the tones of the chord you hold',
                  waitDuration: const Duration(milliseconds: 900),
                  child: SmallSelect<KeyColour>(
                    key: const Key('colour'),
                    value: ctl.colour,
                    items: colours,
                    onChanged: ctl.setColour,
                  ),
                ),
                if (ctl.colour != KeyColour.off && wide) ...[const SizedBox(width: Space.s), ColourLegend(ctl)],
                const SizedBox(width: Space.s),
                TuningChip(ctl),
                if (t != 0) ...[
                  const SizedBox(width: Space.s),
                  Btn(
                    'Transposed ${t > 0 ? '+' : '−'}${t.abs() % 12 == 0 ? '${t.abs() ~/ 12} oct' : '${t.abs()} st'}  ✕',
                    kind: BtnKind.ghost,
                    tooltip: 'Guessed from the octave buttons. Click to reset to D4 in the middle.',
                    onPressed: ctl.resetTranspose,
                  ),
                ],
              ],
            );
            return SizedBox(
              height: Sizes.toolbar,
              child: Row(
                children: [
                  // the controls take their own width, up to all but 200 px; the readout the rest
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: (c.maxWidth - 200).clamp(120.0, c.maxWidth)),
                    child: ClipRect(
                      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: controls),
                    ),
                  ),
                  const SizedBox(width: Space.l),
                  Expanded(
                    child: Align(alignment: Alignment.centerRight, child: HoverReadout(ctl)),
                  ),
                  if (showSound && ctl.voiceName.isNotEmpty) ...[
                    const SizedBox(width: Space.l),
                    Flexible(child: SoundName(ctl, size: TypeSize.title)),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// The legend of the colour mode: a dot per hue with its letter or number, in micro type.
class ColourLegend extends StatelessWidget {
  final AppController ctl;
  const ColourLegend(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final chord = ctl.colour == KeyColour.chord && ctl.harmony.shown?.kind == HarmonyKind.chord && !ctl.harmony.released;
    final items = switch (ctl.colour) {
      KeyColour.function => [for (final e in functionColors.entries) (functionLetters[e.key]!, e.value)],
      KeyColour.chord when chord => [for (final e in chordColors.entries) (chordRoleLetters[e.key]!, e.value)],
      _ => [for (var d = 0; d < 7; d++) ('${d + 1}', degreeColors[d])],
    };
    final tip = switch (ctl.colour) {
      KeyColour.function =>
        'Tonic family: 1 3 6 · Subdominant: 2 4 and a lowered 7 · Dominant: 5 and the leading tone 7.\n'
            'Non-scale keys stay neutral. In other tunings the colouring follows the spelled degrees.',
      KeyColour.chord => chord
          ? 'Root, third, fifth, seventh and extensions of the chord you hold, on every key that carries them'
          : 'Hold a chord to colour its tones across the board; until then the scale degrees',
      _ => 'One hue per scale degree (by letter step: ♭3 and 3 share one); the root is the accent',
    };
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 700),
      child: Row(
        key: const Key('colour-legend'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, col) in items)
            Padding(
              padding: const EdgeInsets.only(right: Space.s - 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: col, width: 1.5)),
                  ),
                  const SizedBox(width: 3),
                  Text(label, style: microStyle(color: Pal.text2)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The active tuning, named from the board's N reply ("31-TET", "custom: fifth 696.8 ¢"), and the
/// fine tune as a reference pitch ("A = 432.0 Hz (−32 ¢)"). The menu holds the pitch reference
/// and, in the demo, the simulated board's tunings.
class TuningChip extends StatelessWidget {
  final AppController ctl;
  const TuningChip(this.ctl, {super.key});

  static const demoTunings = [(0, '12-TET'), (1, '31-TET'), (2, '19-TET'), (3, 'Pythagorean'), (8, 'Just 7-limit')];

  @override
  Widget build(BuildContext context) {
    final t = ctl.tuning;
    final supported = ctl.tuningSupported == true;
    final name = ctl.tuningName;
    final ref = t?.referenceText;
    final tip = !ctl.connected
        ? 'The tuning the board plays (read from it once connected)'
        : supported
        ? '${t!.naming.name}: fifth ${t.fifthCents.toStringAsFixed(1)} ¢, octave ${t.octaveCents.toStringAsFixed(1)} ¢'
              '${t.hasKeyOffsets ? ', per-key offsets' : ''}${ref != null ? '. Fine tune: $ref' : ''}'
              '\nPitch labels are notated relative to this reference.'
        : 'This firmware does not report its tuning (no N command): labels assume 12-TET from the layout';
    final face = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, key: const Key('tuning-chip'), style: ui(TypeSize.small, color: supported ? Pal.text1 : Pal.text3, weight: FontWeight.w500)),
        if (ref != null) ...[
          const SizedBox(width: Space.s),
          Text(ref, key: const Key('reference-chip'), style: ui(TypeSize.small, color: Pal.text2)),
        ],
      ],
    );
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 700),
      child: PopupMenuButton<String>(
        tooltip: '',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 220),
        onSelected: (v) {
          if (v == 'abs') ctl.setPitchRef(PitchRef.absolute);
          if (v == 'root') ctl.setPitchRef(PitchRef.root);
          if (v == 'fine:432') {
            ctl.demoTuning(0, fineCents: -31.77);
          } else if (v.startsWith('demo:')) {
            ctl.demoTuning(int.parse(v.substring(5)), fineCents: 0);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, height: Sizes.row, child: Text('Pitch labels relative to', style: microStyle())),
          for (final (v, l, r) in [('abs', 'A = 440 Hz (the board’s D)', PitchRef.absolute), ('root', 'the key’s root', PitchRef.root)])
            PopupMenuItem(
              value: v,
              height: Sizes.row,
              child: Text(l, style: ui(TypeSize.body, color: ctl.pitchRef == r ? Pal.accent : Pal.text1)),
            ),
          if (ctl.playable) ...[
            const PopupMenuDivider(),
            PopupMenuItem(enabled: false, height: Sizes.row, child: Text('Demo board tuning', style: microStyle())),
            for (final (n, l) in demoTunings)
              PopupMenuItem(
                value: 'demo:$n',
                height: Sizes.row,
                child: Text(l, style: ui(TypeSize.body, color: t?.index == n && (t?.offsetCents.abs() ?? 0) < 0.5 ? Pal.accent : Pal.text1)),
              ),
            PopupMenuItem(
              value: 'fine:432',
              height: Sizes.row,
              child: Text('12-TET at A = 432 Hz', style: ui(TypeSize.body, color: t?.index == 0 && (t?.offsetCents ?? 0) < -1 ? Pal.accent : Pal.text1)),
            ),
          ],
        ],
        child: Container(
          height: Sizes.control,
          padding: const EdgeInsets.symmetric(horizontal: Space.s + 2),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.small), color: supported || ctl.playable ? Pal.bg2 : Colors.transparent),
          alignment: Alignment.center,
          child: face,
        ),
      ),
    );
  }
}

/// Key root (disabled while the scale is Off) and the scale.
class KeyPicker extends StatelessWidget {
  final AppController ctl;
  const KeyPicker(this.ctl, {super.key});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SmallSelect<int>(
        width: 64,
        value: ctl.keyRoot,
        items: ctl.rootChoices,
        onChanged: ctl.keyScale == 'off' ? null : (v) => ctl.setKey(root: v),
      ),
      const SizedBox(width: Space.xs),
      ScalePicker(
        value: ctl.keyScale,
        onChanged: (v) => ctl.setKey(scale: v),
      ),
    ],
  );
}

/// The current sound: name in sound type, the engine in its colour, DEMO in the demo, an accent
/// dot when edited.
class SoundName extends StatelessWidget {
  final AppController ctl;
  final double size;
  final bool stacked;
  const SoundName(this.ctl, {super.key, this.size = TypeSize.sound, this.stacked = false});

  @override
  Widget build(BuildContext context) {
    final engine = ctl.voiceName.isEmpty ? '' : ctl.voiceName.split(':').first;
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ctl.lastSound ?? ctl.nowPreset,
            key: const Key('now-preset'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ui(size, weight: FontWeight.w500, color: ctl.voiceName.isEmpty ? Pal.text3 : Pal.text1),
          ),
          Row(
            children: [
              if (engine.isNotEmpty) Text(engineInfo(engine).label.toLowerCase(), style: ui(TypeSize.small, color: engineColor(engine))),
              if (ctl.mode == ConnMode.demo && ctl.connected) ...[
                const SizedBox(width: Space.s),
                Text(
                  'DEMO',
                  key: const Key('demo-chip'),
                  style: microStyle(color: Pal.demo),
                ),
              ],
            ],
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            ctl.lastSound ?? ctl.nowPreset,
            key: const Key('now-preset'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(size, weight: FontWeight.w500, color: ctl.voiceName.isEmpty ? Pal.text3 : Pal.text1),
          ),
        ),
        if (engine.isNotEmpty) ...[
          const SizedBox(width: Space.s),
          Flexible(
            child: Text(engineInfo(engine).label.toLowerCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.small, color: engineColor(engine))),
          ),
        ],
        if (ctl.mode == ConnMode.demo && ctl.connected) ...[
          const SizedBox(width: Space.s),
          Text(
            'DEMO',
            key: const Key('demo-chip'),
            style: microStyle(color: Pal.demo),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// hero knobs

/// The effect's on/off parameter (demo board: chorus, delay, reverb, trem), if it has one.
Param? fxSwitch(AppController ctl, Param p) => ctl.params[1]!.params.where((q) => q.group == p.group && q.kind == Kind.onOff && q != p).firstOrNull;

class HeroPanel extends StatelessWidget {
  final AppController ctl;
  final double knobSize;
  const HeroPanel(this.ctl, {super.key, this.knobSize = Sizes.knobHero});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final knobs = ctl.mainKnobs();
        final fx = ctl.mainFx();
        Widget grid(List<Param> ps, int t) => Wrap(
          spacing: Space.s,
          runSpacing: Space.m,
          children: [
            for (final p in ps)
              p.kind == Kind.onOff
                  ? ToggleCtl(ctl: ctl, target: t, p: p)
                  : Knob(ctl: ctl, target: t, p: p, size: knobSize, enable: t == 1 ? fxSwitch(ctl, p) : null),
          ],
        );
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SoundName(ctl, stacked: true),
              const SizedBox(height: Space.l),
              if (knobs.isEmpty && fx.isEmpty)
                EmptyNote(
                  !ctl.connected
                      ? "Connect to see this voice's parameters."
                      : ctl.listsLoading
                      ? 'Reading the parameters from the board…'
                      : 'This voice has no live parameters.',
                ),
              if (knobs.isNotEmpty) grid(knobs, 0),
              if (fx.isNotEmpty) ...[const SizedBox(height: Space.xl), grid(fx, 1)],
              if (ctl.hasSound) ...[
                const SizedBox(height: Space.xl),
                Btn('Edit in Sound →', key: const Key('to-sound'), kind: BtnKind.ghost, onPressed: () => ctl.setTab(AppTab.sound)),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 1000-1279 px: the hero knobs and the effect amounts in one row under the board.
class KnobStrip extends StatelessWidget {
  final AppController ctl;
  const KnobStrip(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final knobs = [...ctl.mainKnobs(), ...ctl.mainFx()];
        if (knobs.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: Sizes.knobStrip + 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final p in knobs)
                p.kind == Kind.onOff
                    ? ToggleCtl(ctl: ctl, target: ctl.params[1]!.params.contains(p) ? 1 : 0, p: p)
                    : Knob(
                        ctl: ctl,
                        target: ctl.params[1]!.params.contains(p) ? 1 : 0,
                        p: p,
                        size: Sizes.knobStrip,
                        enable: ctl.params[1]!.params.contains(p) ? fxSwitch(ctl, p) : null,
                      ),
            ],
          ),
        );
      },
    );
  }
}
