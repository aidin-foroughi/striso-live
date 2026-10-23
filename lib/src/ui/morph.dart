// The morph tool (DESIGN.md 3, Sound): a bar at the bottom of the Sound tab, closed at first.
// Open: a 220x220 pad, four corner slots, the source (Hand, Orbit, Tilt), orbit speed and the
// Include effects toggle. One undo entry per gesture.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../morph_model.dart';
import '../theme.dart';

class MorphTool extends StatelessWidget {
  final AppController ctl;
  const MorphTool(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final m = ctl.morph;
        final open = ctl.morphOpen;
        final n = m.filled.where((x) => x).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const Key('morph-toggle'),
                behavior: HitTestBehavior.opaque,
                onTap: () => ctl.setMorphOpen(!open),
                child: SizedBox(
                  height: Sizes.toolbar,
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: open ? 0.25 : 0,
                        duration: Timing.quick,
                        child: const Icon(Icons.chevron_right, size: 18, color: Pal.text2),
                      ),
                      const SizedBox(width: Space.xs),
                      Text('Morph', style: ui(TypeSize.title, weight: FontWeight.w600)),
                      const SizedBox(width: Space.m),
                      if (n > 0) Text('${m.mode.name} · $n corner${n == 1 ? '' : 's'}', style: ui(TypeSize.small, color: Pal.text2)),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: Timing.open,
              curve: Timing.curveOpen,
              alignment: Alignment.topCenter,
              child: open ? SizedBox(height: Sizes.morph, child: _MorphBody(ctl)) : const SizedBox(width: double.infinity),
            ),
          ],
        );
      },
    );
  }
}

class _MorphBody extends StatelessWidget {
  final AppController ctl;
  const _MorphBody(this.ctl);

  @override
  Widget build(BuildContext context) {
    final m = ctl.morph;
    final filled = m.filled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: Sizes.morphPad, height: Sizes.morphPad, child: MorphPad(ctl)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: Space.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: Space.l,
                  runSpacing: Space.s,
                  children: [for (var k = 0; k < 4; k++) SizedBox(width: 220, child: _CornerSlot(ctl, k, filled[k]))],
                ),
                const SizedBox(height: Space.l),
                Wrap(
                  spacing: Space.l,
                  runSpacing: Space.s,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Seg<MorphMode>(
                      value: m.mode,
                      onChanged: (v) {
                        m.setMode(v);
                        ctl.changed();
                      },
                      items: const [
                        (MorphMode.hand, 'Hand', 'Drag the handle'),
                        (MorphMode.orbit, 'Orbit', 'The handle circles on its own'),
                        (MorphMode.tilt, 'Tilt', 'Tilt the instrument to move the handle'),
                      ],
                    ),
                    if (m.mode == MorphMode.orbit)
                      SizedBox(
                        width: 160,
                        child: Slider(
                          value: m.speed,
                          min: 0.03,
                          max: 1.5,
                          onChanged: (v) {
                            m.speed = v;
                            ctl.changed();
                          },
                        ),
                      ),
                    Toggle(
                      value: m.includeFx,
                      label: 'Include effects',
                      onChanged: (v) {
                        m.includeFx = v;
                        ctl.changed();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: Space.s),
                Text(m.hint, style: ui(TypeSize.small, color: Pal.text3)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CornerSlot extends StatelessWidget {
  final AppController ctl;
  final int k;
  final bool filled;
  const _CornerSlot(this.ctl, this.k, this.filled);

  @override
  Widget build(BuildContext context) {
    final m = ctl.morph;
    final c = m.corners[k];
    final name = c == null ? 'Empty' : (filled ? c.name : '${c.name} (other voice)');
    return Row(
      children: [
        Tooltip(
          message: filled ? 'Jump to this corner' : 'Capture the sound into this corner',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                m.goCorner(k);
                ctl.changed();
              },
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? Pal.accent : Colors.transparent,
                  border: Border.all(color: filled ? Pal.accent : Pal.text3, width: 1.5),
                ),
                child: Text(
                  cornerLetters[k],
                  style: ui(TypeSize.small, weight: FontWeight.w600, color: filled ? Pal.accentInk : Pal.text2),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(TypeSize.body, color: c != null && filled ? Pal.text1 : Pal.text3),
          ),
        ),
        Btn(
          c != null ? 'Replace' : 'Capture',
          kind: BtnKind.ghost,
          onPressed: () {
            m.capture(k);
            ctl.changed();
          },
        ),
        if (c != null)
          IconBtn(
            Icons.close,
            tooltip: 'Clear',
            onPressed: () {
              m.clear(k);
              ctl.changed();
            },
          ),
      ],
    );
  }
}

class MorphPad extends StatefulWidget {
  final AppController ctl;
  const MorphPad(this.ctl, {super.key});
  @override
  State<MorphPad> createState() => _MorphPadState();
}

class _MorphPadState extends State<MorphPad> {
  final _focus = FocusNode();
  Size _size = Size.zero;
  static const inset = 0.08;

  (double, double) _pos(Offset p) =>
      (((p.dx / _size.width - inset) / (1 - 2 * inset)).clamp(0.0, 1.0), ((p.dy / _size.height - inset) / (1 - 2 * inset)).clamp(0.0, 1.0));

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.ctl.morph;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (n, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
        final d = HardwareKeyboard.instance.isShiftPressed ? 0.01 : 0.05;
        final k = e.logicalKey;
        final mv = k == LogicalKeyboardKey.arrowLeft
            ? (-d, 0.0)
            : k == LogicalKeyboardKey.arrowRight
            ? (d, 0.0)
            : k == LogicalKeyboardKey.arrowUp
            ? (0.0, -d)
            : k == LogicalKeyboardKey.arrowDown
            ? (0.0, d)
            : null;
        if (mv == null || !m.ready) return KeyEventResult.ignored;
        m.nudge(mv.$1, mv.$2);
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, c) {
          _size = Size(c.maxWidth, c.maxHeight);
          return MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: Listener(
              onPointerDown: (e) {
                _focus.requestFocus();
                final (u, v) = _pos(e.localPosition);
                m.dragStart(u, v);
              },
              onPointerMove: (e) {
                final (u, v) = _pos(e.localPosition);
                m.dragMove(u, v);
              },
              onPointerUp: (_) => m.dragEnd(),
              onPointerCancel: (_) => m.dragEnd(),
              child: Semantics(
                label: 'Morph pad: drag or use the arrow keys',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.popover),
                  child: ColoredBox(
                    color: Pal.bg1,
                    child: CustomPaint(painter: _MorphPainter(widget.ctl), size: Size.infinite),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MorphPainter extends CustomPainter {
  final AppController ctl;
  _MorphPainter(this.ctl) : super(repaint: ctl.morphPulse);

  @override
  void paint(Canvas g, Size size) {
    final m = ctl.morph;
    const inset = 0.08;
    final x0 = size.width * inset, y0 = size.height * inset, w = size.width * (1 - 2 * inset), h = size.height * (1 - 2 * inset);
    final filled = m.filled;
    final ready = m.ready;
    final weights = ready ? cornerWeights(m.u, m.v, filled) : const [0.0, 0.0, 0.0, 0.0];
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Pal.hairline;
    g.drawRect(Rect.fromLTWH(x0, y0, w, h), hair);
    g.drawLine(Offset(x0 + w / 2, y0), Offset(x0 + w / 2, y0 + h), hair);
    g.drawLine(Offset(x0, y0 + h / 2), Offset(x0 + w, y0 + h / 2), hair);
    for (var k = 0; k < 4; k++) {
      final p = Offset(x0 + cornerPos[k].$1 * w, y0 + cornerPos[k].$2 * h);
      g.drawCircle(
        p,
        filled[k] ? 3 + 4 * weights[k] : 2.5,
        Paint()..color = filled[k] ? Pal.accent.withValues(alpha: 0.4 + 0.6 * weights[k]) : Pal.text3,
      );
    }
    if (!ready) return;
    final p = Offset(x0 + m.u * w, y0 + m.v * h);
    if (m.mode == MorphMode.orbit) {
      final tr = m.trail;
      for (var i = 1; i < tr.length; i++) {
        g.drawLine(
          Offset(x0 + tr[i - 1].$1 * w, y0 + tr[i - 1].$2 * h),
          Offset(x0 + tr[i].$1 * w, y0 + tr[i].$2 * h),
          Paint()
            ..strokeWidth = 1
            ..color = Pal.text1.withValues(alpha: 0.3 * i / tr.length),
        );
      }
    }
    for (var k = 0; k < 4; k++) {
      if (!filled[k] || weights[k] < 0.02) continue;
      g.drawLine(
        p,
        Offset(x0 + cornerPos[k].$1 * w, y0 + cornerPos[k].$2 * h),
        Paint()
          ..strokeWidth = 1
          ..color = Pal.accent.withValues(alpha: 0.15 + 0.5 * weights[k]),
      );
    }
    g.drawCircle(p, 6, Paint()..color = Pal.accent);
  }

  @override
  bool shouldRepaint(covariant _MorphPainter old) => true;
}
