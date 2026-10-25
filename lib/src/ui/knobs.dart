// Knob and parameter toggle (DESIGN.md 4.2). Drag up/down (Shift: fine), scroll, arrow keys;
// double-click resets to the value read from the board; Alt+click locks against Mutate. The label
// shows the name; while hovered or dragged it shows the value. An accent dot marks an edit.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';

String prettyName(String n) => n.replaceAll('_', ' ');

bool get _alt => HardwareKeyboard.instance.isAltPressed;
bool get _shift => HardwareKeyboard.instance.isShiftPressed;

class Knob extends StatefulWidget {
  final AppController ctl;
  final int target;
  final Param p;
  final double size;

  /// The knob's group is switched off (an effect): drawn at 40%, still editable; a tap enables.
  final Param? enable;
  const Knob({super.key, required this.ctl, required this.target, required this.p, this.size = Sizes.knob, this.enable});
  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double? _raw;
  bool _began = false, _hover = false, _drag = false;
  Timer? _endTimer;
  final _focus = FocusNode();

  Param get p => widget.p;
  int get t => widget.target;
  AppController get ctl => widget.ctl;
  double get span => (p.max - p.min) == 0 ? 1 : p.max - p.min;

  @override
  void dispose() {
    _endTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _soonEnd() {
    _endTimer?.cancel();
    _endTimer = Timer(const Duration(milliseconds: 700), () => ctl.onEdit(t, p, p.value, 'end'));
  }

  void _step(double dir, {bool fine = false, String key = 'wheel'}) {
    final step = p.kind == Kind.integer ? 1.0 : span / (fine ? 1000 : 100);
    final v = conformValue(p, p.value + dir * step);
    if (v == p.value) return;
    ctl.onEdit(t, p, v, 'begin', 'Change ${p.name}', '$key:$t:${p.index}');
    _soonEnd();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final unit = p.kind == Kind.integer ? 1.0 : span / 100;
    final fine = _shift && p.kind != Kind.integer ? 0.1 : 1.0;
    double? v;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowRight) v = p.value + unit * fine;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowLeft) v = p.value - unit * fine;
    if (k == LogicalKeyboardKey.pageUp) v = p.value + unit * 10 * fine;
    if (k == LogicalKeyboardKey.pageDown) v = p.value - unit * 10 * fine;
    if (k == LogicalKeyboardKey.home) v = p.min;
    if (k == LogicalKeyboardKey.end) v = p.max;
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) v = p.loadValue;
    if (v == null) return KeyEventResult.ignored;
    v = conformValue(p, v);
    if (v != p.value) {
      ctl.onEdit(t, p, v, 'begin', 'Change ${p.name}', 'key:$t:${p.index}');
      _soonEnd();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Tooltip(
      message:
          '${prettyName(p.name)}: ${formatParam(p, p.min)} to ${formatParam(p, p.max)}${p.kind == Kind.integer ? ', steps' : ''}\n'
          'Drag, scroll or use the arrow keys. Double-click resets. Alt+click locks.',
      waitDuration: const Duration(milliseconds: 900),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (_) => setState(() {}),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                GestureBinding.instance.pointerSignalResolver.register(e, (_) => _step(e.scrollDelta.dy < 0 ? 1 : -1, fine: _shift));
              }
            },
            child: GestureDetector(
              onTapDown: (_) {
                _focus.requestFocus();
                if (_alt) ctl.toggleLock(t, p);
              },
              onTap: () {
                final en = widget.enable;
                if (en != null && en.value < 0.5 && !_alt) {
                  ctl.onEdit(1, en, 1, 'begin', 'Switch ${en.name} on');
                  ctl.onEdit(1, en, 1, 'end');
                }
              },
              onDoubleTap: () {
                ctl.onEdit(t, p, p.loadValue, 'begin', 'Reset ${p.name}');
                ctl.onEdit(t, p, p.loadValue, 'end');
              },
              onPanStart: (_) {
                if (_alt) return;
                _raw = p.value;
                _began = false;
                setState(() => _drag = true);
              },
              onPanUpdate: (d) {
                final raw = _raw;
                if (raw == null) return;
                final fine = _shift ? 6 : 1;
                final dy = -d.delta.dy + d.delta.dx * 0.25;
                final next = (raw + (dy / (200 * fine)) * span).clamp(p.min, p.max).toDouble();
                _raw = next;
                final v = conformValue(p, next);
                if (v == p.value) return;
                if (!_began) {
                  _began = true;
                  ctl.onEdit(t, p, v, 'begin', 'Change ${p.name}');
                } else {
                  ctl.onEdit(t, p, v, 'change');
                }
              },
              onPanEnd: (_) {
                if (_began) ctl.onEdit(t, p, p.value, 'end');
                _raw = null;
                _began = false;
                setState(() => _drag = false);
              },
              child: ListenableBuilder(
                listenable: ctl.values,
                builder: (context, _) {
                  final changed = p.value != p.loadValue;
                  // sent, not yet read back from the board: the arc and the dot stay faint
                  final pending = ctl.sound.isPending(t, p);
                  final locked = ctl.locks[t]?.contains(p.name) ?? false;
                  final off = widget.enable != null && widget.enable!.value < 0.5;
                  final showValue = _hover || _drag || _focus.hasFocus;
                  return Opacity(
                    opacity: off ? 0.4 : 1,
                    child: SizedBox(
                      width: math.max(size + 16, 64),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: size,
                            height: size,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _DialPainter(p, p.value, focused: _focus.hasFocus, tracksOnly: ctl.listsLoading, pending: pending),
                                  ),
                                ),
                                if (locked) const Positioned(right: -6, top: -4, child: Icon(Icons.lock, size: 10, color: Pal.text3)),
                              ],
                            ),
                          ),
                          const SizedBox(height: Space.xs),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  showValue ? formatParam(p) : prettyName(p.name),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: ui(TypeSize.body, color: showValue ? Pal.text1 : Pal.text2),
                                ),
                              ),
                              if (pending) ...[
                                const SizedBox(width: Space.xs),
                                const Pip(Pal.accent, key: Key('pending'), size: 4, hollow: true),
                              ] else if (changed) ...[
                                const SizedBox(width: Space.xs),
                                const Pip(Pal.accent, size: 4),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final Param p;
  final double value;
  final bool focused, tracksOnly, pending;
  _DialPainter(this.p, this.value, {this.focused = false, this.tracksOnly = false, this.pending = false});

  @override
  void paint(Canvas c, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 1.5;
    final span = (p.max - p.min) == 0 ? 1 : p.max - p.min;
    final f = ((value - p.min) / span).clamp(0.0, 1.0);
    final bipolar = p.min < 0 && p.max > 0;
    final zero = bipolar ? (0 - p.min) / span : 0.0;
    const sweep = 270.0;
    double ang(double x) => (135 + sweep * x) * math.pi / 180; // 7:30 is 135 degrees
    final rect = Rect.fromCircle(center: center, radius: r);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    c.drawArc(rect, ang(0), sweep * math.pi / 180, false, arc..color = Pal.bg3);
    if (!tracksOnly) {
      final a = math.min(f, zero), b = math.max(f, zero);
      if (b - a > 1e-4) {
        c.drawArc(rect, ang(a), (b - a) * sweep * math.pi / 180, false, arc..color = pending ? Pal.accent.withValues(alpha: 0.45) : Pal.accent);
      }
    }
    final disc = r - 5;
    c.drawCircle(center, disc, Paint()..color = Pal.bg2);
    if (focused) {
      c.drawCircle(
        center,
        r + 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Pal.accent,
      );
    }
    if (!tracksOnly) {
      final na = ang(f);
      final dir = Offset(math.cos(na), math.sin(na));
      c.drawLine(
        center + dir * (disc * 0.35),
        center + dir * (disc - 2),
        Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = Pal.text1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.value != value || old.focused != focused || old.tracksOnly != tracksOnly || old.pending != pending;
}

/// An on/off parameter: a pill toggle with its name at the right.
class ToggleCtl extends StatelessWidget {
  final AppController ctl;
  final int target;
  final Param p;
  final bool showName;
  const ToggleCtl({super.key, required this.ctl, required this.target, required this.p, this.showName = true});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${prettyName(p.name)}: on/off. Alt+click locks.',
      waitDuration: const Duration(milliseconds: 900),
      child: ListenableBuilder(
        listenable: ctl.values,
        builder: (context, _) {
          final on = p.value >= 0.5;
          final locked = ctl.locks[target]?.contains(p.name) ?? false;
          final pending = ctl.sound.isPending(target, p);
          return Opacity(
            opacity: pending ? 0.5 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Toggle(
                    value: on,
                    label: showName ? prettyName(p.name) : null,
                    onChanged: (v) {
                      if (_alt) return ctl.toggleLock(target, p);
                      ctl.onEdit(target, p, v ? 1 : 0, 'begin', 'Switch ${p.name}');
                      ctl.onEdit(target, p, v ? 1 : 0, 'end');
                    },
                  ),
                  if (p.value != p.loadValue) ...[const SizedBox(width: Space.xs), const Pip(Pal.accent, size: 4)],
                  if (locked) ...[const SizedBox(width: Space.xs), const Icon(Icons.lock, size: 10, color: Pal.text3)],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
