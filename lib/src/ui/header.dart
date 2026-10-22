// The header (name, current voice, connection, a small CPU indicator, Connect) and the tabs.

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
    return Container(
      height: Sizes.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: Space.l),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Pal.headerTop, Pal.headerBottom]),
      ),
      child: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) {
            final v = ctl.version;
            final statusTip = [
              ctl.status,
              if (v != null) 'Firmware ${v.fw}',
              if (v != null) ...[v.line, ...v.extra],
            ].join('\n');
            return Row(
              children: [
                const BrandMark(size: 22),
                const SizedBox(width: Space.s),
                if (box.maxWidth >= 640)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'Striso', style: ui(TypeSize.heading - 2, color: Pal.honey, weight: FontWeight.w600)),
                        TextSpan(text: ' Live', style: ui(TypeSize.heading - 2, weight: FontWeight.w300)),
                      ],
                    ),
                  ),
                const SizedBox(width: Space.xl),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      if (ctl.nowEngine.isNotEmpty && box.maxWidth >= 760) ...[
                        Flexible(child: Text(ctl.nowEngine, maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.body, color: Pal.muted))),
                        const SizedBox(width: Space.s),
                      ],
                      Flexible(
                        child: Text(
                          ctl.nowPreset,
                          key: const Key('now-preset'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            TypeSize.voice,
                            color: ctl.voiceName.isEmpty ? Pal.faint : Pal.honey,
                            weight: ctl.voiceName.isEmpty ? FontWeight.w300 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (ctl.connected && box.maxWidth >= 900) ...[CpuIndicator(ctl), const SizedBox(width: Space.xl)],
                Tooltip(
                  message: statusTip,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(ctl.dot),
                      const SizedBox(width: Space.s),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: box.maxWidth < 760 ? 120 : 260),
                        child: Text(ctl.status, key: const Key('status'), maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.label)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.m),
                Btn(ctl.connectLabel, key: const Key('btn-connect'), kind: BtnKind.primary, onPressed: ctl.connecting ? null : ctl.connectButton),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The synth load, small: the average now and a sparkline; the details in the tooltip.
class CpuIndicator extends StatelessWidget {
  final AppController ctl;
  const CpuIndicator(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final l = ctl.load;
    final col = l == null ? Pal.muted : (l.peakPct > 85 ? Pal.danger : (l.peakPct > 60 ? Pal.honey : Pal.text));
    return Tooltip(
      message: l == null
          ? (ctl.loadNa ? 'This firmware does not report synth load (no L command).' : 'Synth DSP load, read from the board every second')
          : 'Synth CPU: avg ${l.avgPct.toStringAsFixed(0)}%, peak ${l.peakPct.toStringAsFixed(0)}% over the last second '
                '(${l.blocks} blocks, avg ${l.avg} and peak ${l.peak} of ${l.budget} cycles per block)',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('CPU', style: ui(TypeSize.caption, color: Pal.faint)),
          const SizedBox(width: Space.s),
          SizedBox(
            width: 34,
            child: Text(
              l != null ? '${l.avgPct.toStringAsFixed(0)}%' : (ctl.loadNa ? 'n/a' : '–'),
              textAlign: TextAlign.right,
              style: ui(TypeSize.label, color: col, weight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.s),
          SizedBox(width: 56, height: 18, child: CustomPaint(painter: LoadSparkline(List.of(ctl.loadHist)))),
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
    final w = s.width, hh = s.height;
    g.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(3)), Paint()..color = Pal.line.withValues(alpha: 0.35));
    if (h.isEmpty) return;
    const n = 40;
    final pts = h.length > n ? h.sublist(h.length - n) : h;
    final dx = w / (n - 1);
    double x(int i) => w - (pts.length - 1 - i) * dx;
    double y(double pct) => hh - math.min(1, pct / 100) * hh;
    final area = Path()..moveTo(x(0), hh);
    for (var i = 0; i < pts.length; i++) {
      area.lineTo(x(i), y(pts[i].avgPct));
    }
    area
      ..lineTo(x(pts.length - 1), hh)
      ..close();
    g.drawPath(area, Paint()..color = Pal.honey.withValues(alpha: 0.45));
    final peak = Path();
    for (var i = 0; i < pts.length; i++) {
      i == 0 ? peak.moveTo(x(i), y(pts[i].peakPct)) : peak.lineTo(x(i), y(pts[i].peakPct));
    }
    g.drawPath(
      peak,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Pal.ember,
    );
  }

  @override
  bool shouldRepaint(covariant LoadSparkline old) => true;
}

/// Play, Sound, Setup.
class TabStrip extends StatelessWidget {
  final AppController ctl;
  const TabStrip(this.ctl, {super.key});

  static const _labels = {AppTab.play: 'Play', AppTab.sound: 'Sound', AppTab.setup: 'Setup'};
  static const _tips = {
    AppTab.play: 'Voices, the board, chords and the main knobs',
    AppTab.sound: 'Every voice and effect parameter, your sounds, the morph pad',
    AppTab.setup: 'Touch sensitivity, key equalizer, settings keys, Save to Striso, motion',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => Container(
        height: Sizes.tabHeight,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        decoration: const BoxDecoration(
          color: Pal.headerBottom,
          border: Border(bottom: BorderSide(color: Pal.seam)),
        ),
        child: Row(
          children: [
            for (final t in AppTab.values)
              _TabButton(label: _labels[t]!, tip: _tips[t]!, on: ctl.tab == t, onTap: () => ctl.setTab(t), key: Key('tab-${t.name}')),
          ],
        ),
      ),
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
          child: AnimatedContainer(
            duration: Timing.fast,
            padding: const EdgeInsets.symmetric(horizontal: Space.l),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: widget.on ? Pal.honey : Colors.transparent, width: 2)),
            ),
            child: Text(
              widget.label,
              style: ui(TypeSize.body, color: widget.on || _hover ? Pal.text : Pal.muted, weight: widget.on ? FontWeight.w600 : FontWeight.w400),
            ),
          ),
        ),
      ),
    );
  }
}
