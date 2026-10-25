// The header (DESIGN.md 3, docs/flows.md 3): brand and name, the instrument (Striso | Virtual),
// the tabs centred, the CPU sparkline, Through PC while the Striso plays (a toggle and a level
// pip; the recording time while recording) or the MIDI input while Virtual plays, the status line
// (a click opens the console) and the one button that ends what plays (Disconnect, Stop, Cancel).
// In stage mode it shrinks to a 24 px strip.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../firmware_library.dart';
import 'build_picker.dart';
import 'midi_picker.dart';
import '../theme.dart';
import 'audio.dart';
import 'chrome.dart';

class TopBar extends StatelessWidget {
  final AppController ctl;
  const TopBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl, ctl.audioState]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 1100;
          // Through PC's label only where there is room; the status text gets what is left of the
          // right half after the centred tabs, so the two never meet
          final throughLabel = box.maxWidth >= 1280;
          final rightRoom = box.maxWidth / 2 - 110 - Space.gutter;
          final others =
              (ctl.connected && box.maxWidth >= 1000 ? 56 + Space.s + 32 + Space.xl : 0) +
              (ctl.playing == Mode.virtual && !narrow ? 40 : 0) +
              150 +
              (throughLabel ? 118 : 46) +
              Space.l +
              (ctl.audio.recording ? 60 : 0) +
              16 +
              Space.m +
              (ctl.connectLabel.isEmpty ? 0 : 104);
          final statusMax = (rightRoom - others).clamp(72.0, narrow ? 140.0 : 280.0);
          return Container(
            height: Sizes.header,
            color: Pal.bg0,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  children: [
                    const BrandMark(),
                    const SizedBox(width: Space.s),
                    if (!narrow) ...[
                      Text('Striso', style: ui(TypeSize.title, weight: FontWeight.w600)),
                      Text(' Live', style: ui(TypeSize.title, color: Pal.text2)),
                    ],
                    const SizedBox(width: Space.l),
                    ModeControl(ctl, compact: narrow),
                    const Spacer(),
                    if (ctl.connected && box.maxWidth >= 1000) ...[CpuIndicator(ctl), const SizedBox(width: Space.xl)],
                    if (ctl.playing == Mode.virtual) InputPicker(ctl, label: throughLabel) else if (ctl.playing == Mode.striso) ThroughToggle(ctl, label: throughLabel),
                    RecIndicator(ctl),
                    const SizedBox(width: Space.l),
                    ConnectionStatus(ctl, maxWidth: statusMax),
                    if (ctl.connectLabel.isNotEmpty) ...[
                      const SizedBox(width: Space.m),
                      Btn(
                        ctl.connectLabel,
                        key: const Key('btn-connect'),
                        kind: BtnKind.secondary,
                        tooltip: switch (ctl.connectLabel) {
                          'Disconnect' => 'Let go of the Striso: its console, Through PC and the pollers end. It stays away until you click Striso again.',
                          'Stop' => 'Stop Virtual: its sound and MIDI inputs close. Nothing plays.',
                          _ => 'Do not connect',
                        },
                        onPressed: ctl.saving ? null : ctl.connectButton,
                      ),
                    ],
                  ],
                ),
                TabRow(ctl),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The status dot and text; the tooltip has the firmware version and the stream numbers, a click
/// opens the console.
class ConnectionStatus extends StatelessWidget {
  final AppController ctl;
  final double maxWidth;
  const ConnectionStatus(this.ctl, {super.key, this.maxWidth = 280});

  @override
  Widget build(BuildContext context) {
    final v = ctl.version;
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.stats, ctl.audioState]),
      builder: (context, _) {
        final line = ctl.saving ? 'Saving to the Striso…' : ctl.statusLine;
        final tip = [
          ctl.status,
          if (ctl.soundLine.isNotEmpty) ctl.soundLine,
          if (v != null) 'Firmware ${v.fw}',
          'Running: ${ctl.session.resources}',
          if (ctl.connected) '${ctl.live.activeCount()} keys down, ${ctl.live.rate.round()} messages/s${ctl.streamStalled ? ' (stream silent)' : ''}',
          'Click for the console',
        ].join('\n');
        return Tooltip(
          message: tip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => ctl.setConsole(!ctl.consoleOpen),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(ctl.dot, lost: ctl.lost || ctl.problem != null),
                  const SizedBox(width: Space.s),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Text(
                      line,
                      key: const Key('status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(TypeSize.body, color: Pal.text2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Play, Sound, Setup: body 500; the selected one text1 with a 2 px accent underline.
class TabRow extends StatelessWidget {
  final AppController ctl;
  const TabRow(this.ctl, {super.key});

  static const _labels = {AppTab.play: 'Play', AppTab.sound: 'Sound', AppTab.setup: 'Setup'};
  static const _tips = {
    AppTab.play: 'Voices, the board, chords and the hero knobs (Ctrl+1)',
    AppTab.sound: 'Every voice and effect parameter, your sounds, the morph pad (Ctrl+2)',
    AppTab.setup: 'Touch sensitivity, key equalizer, settings keys, Save to Striso (Ctrl+3)',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in AppTab.values)
          _TabButton(label: _labels[t]!, tip: _tips[t]!, on: ctl.tab == t, onTap: () => ctl.setTab(t), key: Key('tab-${t.name}')),
      ],
    );
  }
}

class _TabButton extends StatefulWidget {
  final String label, tip;
  final bool on;
  final VoidCallback onTap;
  const _TabButton({super.key, required this.label, required this.tip, required this.on, required this.onTap});
  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final style = ui(TypeSize.body, weight: FontWeight.w500, color: widget.on ? Pal.text1 : (_hover ? Pal.text2 : Pal.text3));
    return Tooltip(
      message: widget.tip,
      waitDuration: const Duration(milliseconds: 900),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: Sizes.header,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 4),
                  Text(widget.label, style: style),
                  const SizedBox(height: Space.xs),
                  AnimatedContainer(
                    duration: Timing.quick,
                    height: 2,
                    width: widget.on ? textWidthOf(widget.label, style) - 8 : 0,
                    color: Pal.accent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double textWidthOf(String s, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return math.max(0, tp.width);
}

/// The synth load: a 56x14 sparkline (text3, accent above 70%) and the average in small.
class CpuIndicator extends StatelessWidget {
  final AppController ctl;
  const CpuIndicator(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final l = ctl.load;
    final hot = l != null && l.avgPct > 70;
    return Tooltip(
      message: l == null
          ? (ctl.loadNa ? 'This firmware does not report synth load (no L command).' : 'Synth DSP load, read from the board every second')
          : 'Synth CPU: avg ${l.avgPct.toStringAsFixed(0)}%, peak ${l.peakPct.toStringAsFixed(0)}% over the last second\n'
                '${l.blocks} blocks, avg ${l.avg} and peak ${l.peak} of ${l.budget} cycles per block',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 56, height: 14, child: CustomPaint(painter: LoadSparkline(List.of(ctl.loadHist)))),
          const SizedBox(width: Space.s),
          Text(
            l != null ? '${l.avgPct.toStringAsFixed(0)}%' : (ctl.loadNa ? 'n/a' : '–'),
            style: ui(TypeSize.small, color: hot ? Pal.accent : Pal.text2),
          ),
        ],
      ),
    );
  }
}

class LoadSparkline extends CustomPainter {
  final List<LoadReading> h;
  LoadSparkline(this.h);

  @override
  void paint(Canvas g, Size s) {
    if (h.isEmpty) return;
    const n = 40;
    final pts = h.length > n ? h.sublist(h.length - n) : h;
    final dx = s.width / (n - 1);
    final line = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = s.width - (pts.length - 1 - i) * dx, y = s.height - math.min(1, pts[i].avgPct / 100) * s.height;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    g.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = pts.last.avgPct > 70 ? Pal.accent : Pal.text3,
    );
  }

  @override
  bool shouldRepaint(covariant LoadSparkline old) => true;
}

/// Striso | Virtual: what plays. Striso connects the board (a click on it while it plays does
/// nothing). Virtual opens the build chooser, the next thing to choose; while Virtual plays the
/// button carries the build's title and reopens the chooser; ⇄ next to it goes back to the build
/// played before, on the same key.
class ModeControl extends StatelessWidget {
  final AppController ctl;
  final bool compact;
  const ModeControl(this.ctl, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final busy = ctl.saving;
    final playing = ctl.playing;
    final prev = ctl.previousBuild;
    return Opacity(
      opacity: busy ? 0.35 : 1,
      child: IgnorePointer(
        ignoring: busy,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Btn(
              'Striso',
              key: const Key('mode-striso'),
              kind: BtnKind.ghost,
              pressed: playing == Mode.striso,
              tooltip: playing == Mode.striso
                  ? 'Your Striso over USB plays: its own sound, its voices and settings'
                  : ctl.boardPresent
                  ? 'Connect your Striso over USB (it is plugged in)'
                  : 'Your Striso over USB (none is plugged in)',
              onPressed: () {
                if (playing != Mode.striso) ctl.userConnect();
              },
            ),
            Builder(
              builder: (ctx) => Btn(
                virtualLabel(ctl, compact: compact),
                key: const Key('mode-virtual'),
                kind: BtnKind.ghost,
                pressed: playing == Mode.virtual,
                tooltip: playing == Mode.virtual
                    ? 'Virtual plays ${ctl.virtual.isMock ? 'the Dart mock' : (ctl.virtual.buildTitle ?? 'a build')}: pick another build'
                    : 'Virtual: the Striso firmware on this computer, played from MIDI controllers (your Striso too) and the on-screen board. Pick the build to play.',
                onPressed: () => showBuildChooser(ctx, ctl),
              ),
            ),
            if (playing == Mode.virtual && prev != null)
              IconBtn(
                Icons.swap_horiz,
                key: const Key('build-swap'),
                tooltip: 'Back to ${ctl.swapTitle ?? buildOf(prev).title}',
                onPressed: ctl.swapBuild,
              ),
          ],
        ),
      ),
    );
  }
}
