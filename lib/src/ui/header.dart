// The header (DESIGN.md 3): brand and name, the tabs centred, the CPU sparkline, the connection
// (a click opens the console) and Connect / Disconnect. In stage mode it shrinks to a 24 px strip.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';

class TopBar extends StatelessWidget {
  final AppController ctl;
  const TopBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 1100;
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
                    const Spacer(),
                    if (ctl.connected) ...[CpuIndicator(ctl), const SizedBox(width: Space.xl)],
                    ConnectionStatus(ctl, maxWidth: narrow ? 140 : 280),
                    const SizedBox(width: Space.m),
                    Btn(
                      ctl.connectLabel,
                      key: const Key('btn-connect'),
                      kind: !ctl.connected && ctl.boardPresent && !ctl.reconnectPending ? BtnKind.primary : BtnKind.secondary,
                      onPressed: ctl.connecting ? null : ctl.connectButton,
                    ),
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
      listenable: ctl.stats,
      builder: (context, _) {
        final tip = [
          ctl.status,
          if (v != null) 'Firmware ${v.fw}',
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
                  StatusDot(ctl.dot, lost: ctl.lost),
                  const SizedBox(width: Space.s),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Text(
                      ctl.saving ? 'Saving to the Striso…' : (ctl.mode == ConnMode.demo && ctl.connected ? 'Demo' : ctl.status),
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
