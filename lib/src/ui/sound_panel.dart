// Sound editor racks: one module per parameter group, a knob per continuous or integer parameter
// and a switch per on/off parameter. Drag up/down (Shift for fine), scroll, arrow keys;
// double-click resets to the value read from the board; Alt+click locks against Mutate.
// Port of tools/app/js/editor.js.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';

String prettyName(String n) => n.replaceAll('_', ' ');

class SoundPanel extends StatelessWidget {
  final AppController ctl;
  const SoundPanel(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final any = ctl.hasSound;
        final v = ctl.params[0]!, f = ctl.params[1]!;
        String empty(int t) {
          if (ctl.connected && ctl.listsLoading) return 'Reading the parameters from the board…';
          if (t == 0) {
            return !ctl.connected
                ? "Connect to see this voice's parameters."
                : v.missing
                ? 'The board did not list parameters (firmware without live parameters?).'
                : 'This voice has no live parameters yet.';
          }
          return !ctl.connected
              ? 'Connect to see the master effects.'
              : f.missing
              ? 'The board did not list effect parameters.'
              : 'The master effects have no live parameters yet.';
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Sound', style: ui(15, weight: FontWeight.w600)),
                  Btn('Undo', key: const Key('btn-undo'), small: true, tooltip: 'Undo (Ctrl+Z)', onPressed: ctl.history.canUndo ? ctl.undo : null),
                  Btn(
                    'Redo',
                    key: const Key('btn-redo'),
                    small: true,
                    tooltip: 'Redo (Ctrl+Shift+Z)',
                    onPressed: ctl.history.canRedo ? ctl.redo : null,
                  ),
                  const SizedBox(width: 40),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SmallSelect<String>(
                        value: ctl.mutateScope,
                        items: const [('0', 'Voice'), ('1', 'Effects'), ('both', 'Both')],
                        onChanged: ctl.setMutateScope,
                      ),
                      SizedBox(
                        width: 110,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(activeTrackColor: Pal.honey, thumbColor: Pal.honey),
                          child: StatefulBuilder(
                            builder: (context, setState) =>
                                Slider(value: ctl.mutateAmount, min: 0.02, max: 0.5, onChanged: (x) => setState(() => ctl.mutateAmount = x)),
                          ),
                        ),
                      ),
                      Btn(
                        'Mutate',
                        key: const Key('btn-mutate'),
                        small: true,
                        tooltip: 'Small random changes within the ranges (M). Alt+click a knob to lock it.',
                        onPressed: any ? ctl.mutate : null,
                      ),
                    ],
                  ),
                  Btn('Reset all', small: true, tooltip: 'Back to the values read from the board', onPressed: any ? ctl.resetAll : null),
                  Btn(
                    'Copy as C',
                    small: true,
                    tooltip: 'C arrays for the firmware preset tables',
                    onPressed: any && ctl.voiceName.isNotEmpty ? () => showCode(context, ctl, ctl.currentAsPreset()) : null,
                  ),
                ],
              ),
            ),
            _Rack(
              ctl: ctl,
              target: 0,
              title: 'Voice',
              sub: v.name.isNotEmpty ? '${v.name}, ${v.params.length} parameters' : '',
              accent: Pal.honey,
              accentDim: Pal.honeyDim,
              empty: empty(0),
            ),
            Container(height: 1, color: Pal.seam),
            _Rack(
              ctl: ctl,
              target: 1,
              title: 'Effects',
              sub: f.params.isNotEmpty ? '${f.params.length} parameters' : '',
              accent: Pal.glacier,
              accentDim: Pal.glacierDim,
              empty: empty(1),
            ),
          ],
        );
      },
    );
  }
}

class _Rack extends StatelessWidget {
  final AppController ctl;
  final int target;
  final String title, sub, empty;
  final Color accent, accentDim;
  const _Rack({
    required this.ctl,
    required this.target,
    required this.title,
    required this.sub,
    required this.accent,
    required this.accentDim,
    required this.empty,
  });

  @override
  Widget build(BuildContext context) {
    final list = ctl.params[target]!.params;
    final groups = <String, List<Param>>{};
    for (final p in list) {
      (groups[p.group] ??= []).add(p);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(title, style: ui(13.5, weight: FontWeight.w600)),
              const SizedBox(width: 10),
              Text(sub, style: ui(12, color: Pal.faint)),
            ],
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
            child: Text(empty, style: ui(13, color: Pal.faint)),
          )
        else
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Pal.seam)),
            ),
            child: Wrap(
              children: [
                for (final MapEntry(key: name, value: ps) in groups.entries)
                  Container(
                    constraints: const BoxConstraints(minWidth: 120),
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    decoration: const BoxDecoration(
                      border: Border(
                        right: BorderSide(color: Pal.seam),
                        bottom: BorderSide(color: Pal.seam),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 0, 0, 4),
                          child: Text(prettyName(name), style: ui(12, color: accent)),
                        ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 2,
                          children: [
                            for (final p in ps)
                              p.kind == Kind.onOff
                                  ? ToggleCtl(ctl: ctl, target: target, p: p, accent: accent, accentDim: accentDim)
                                  : Knob(ctl: ctl, target: target, p: p, accent: accent),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

bool get _alt => HardwareKeyboard.instance.isAltPressed;
bool get _shift => HardwareKeyboard.instance.isShiftPressed;

class Knob extends StatefulWidget {
  final AppController ctl;
  final int target;
  final Param p;
  final Color accent;
  const Knob({super.key, required this.ctl, required this.target, required this.p, required this.accent});
  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double? _raw;
  bool _began = false, _hover = false;
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
    return Tooltip(
      message:
          '${p.name}  ${formatParam(p, p.min)} to ${formatParam(p, p.max)}${p.kind == Kind.integer ? ', steps' : ''}\n'
          'Drag, scroll or use the arrow keys. Double-click resets. Alt+click locks.',
      waitDuration: const Duration(milliseconds: 900),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
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
              onDoubleTap: () {
                ctl.onEdit(t, p, p.loadValue, 'begin', 'Reset ${p.name}');
                ctl.onEdit(t, p, p.loadValue, 'end');
              },
              onPanStart: (_) {
                if (_alt) return;
                _raw = p.value;
                _began = false;
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
              },
              child: ListenableBuilder(
                listenable: ctl.values,
                builder: (context, _) {
                  final changed = p.value != p.loadValue;
                  final locked = ctl.locks[t]?.contains(p.name) ?? false;
                  return Opacity(
                    opacity: locked ? 0.5 : 1,
                    child: Container(
                      width: 68,
                      padding: const EdgeInsets.fromLTRB(0, 2, 0, 4),
                      decoration: BoxDecoration(
                        color: _hover ? const Color(0x08FFFFFF) : null,
                        borderRadius: BorderRadius.circular(6),
                        border: _focus.hasFocus ? Border.all(color: Pal.glacier, width: 1.5) : null,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: 48, height: 48, child: CustomPaint(painter: _DialPainter(p, widget.accent, changed))),
                          Text(
                            '${locked ? '\u{1F512}︎ ' : ''}${prettyName(p.name)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: ui(11.5, color: Pal.muted, height: 1.1),
                          ),
                          Text(formatParam(p), style: ui(12.5, color: changed ? widget.accent : Pal.text, height: 1.2)),
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
  final Color accent;
  final bool changed;
  final double value, home;
  _DialPainter(this.p, this.accent, this.changed) : value = p.value, home = p.loadValue;

  @override
  void paint(Canvas c, Size size) {
    final k = size.width / 56;
    final center = Offset(28 * k, 28 * k), r = 21 * k;
    final span = (p.max - p.min) == 0 ? 1 : p.max - p.min;
    double frac(double v) => ((v - p.min) / span).clamp(0.0, 1.0);
    final f = frac(value);
    final zero = p.min < 0 && p.max > 0 ? (0 - p.min) / span : 0.0;
    const start = -135.0, sweep = 270.0;
    double ang(double x) => (start + sweep * x - 90) * math.pi / 180;
    final rect = Rect.fromCircle(center: center, radius: r);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * k
      ..strokeCap = StrokeCap.round;
    c.drawArc(rect, ang(0), sweep * math.pi / 180, false, arc..color = Pal.line);
    final a = math.min(f, zero), b = math.max(f, zero);
    if (b - a > 1e-4) c.drawArc(rect, ang(a), (b - a) * sweep * math.pi / 180, false, arc..color = accent);
    if (changed) {
      final h = ang(frac(home));
      c.drawCircle(center + Offset(math.cos(h), math.sin(h)) * r, 1.9 * k, Paint()..color = Pal.muted.withValues(alpha: 0.9));
    }
    c.drawCircle(center, 14.5 * k, Paint()..color = const Color(0xFF2B2640));
    c.drawCircle(
      center,
      14.5 * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = k
        ..color = const Color(0xFF48416A),
    );
    final na = ang(f);
    final dir = Offset(math.cos(na), math.sin(na));
    c.drawLine(
      center + dir * 4 * k,
      center + dir * 13 * k,
      Paint()
        ..strokeWidth = 2.4 * k
        ..strokeCap = StrokeCap.round
        ..color = Pal.text,
    );
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) => old.value != value || old.home != home || old.changed != changed || old.accent != accent;
}

class ToggleCtl extends StatelessWidget {
  final AppController ctl;
  final int target;
  final Param p;
  final Color accent, accentDim;
  const ToggleCtl({super.key, required this.ctl, required this.target, required this.p, required this.accent, required this.accentDim});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${p.name}: on/off. Alt+click locks.',
      waitDuration: const Duration(milliseconds: 900),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (_alt) return ctl.toggleLock(target, p);
            final v = p.value >= 0.5 ? 0.0 : 1.0;
            ctl.onEdit(target, p, v, 'begin', 'Switch ${p.name}');
            ctl.onEdit(target, p, v, 'end');
          },
          child: ListenableBuilder(
            listenable: ctl.values,
            builder: (context, _) {
              final on = p.value >= 0.5;
              final changed = p.value != p.loadValue;
              final locked = ctl.locks[target]?.contains(p.name) ?? false;
              return Opacity(
                opacity: locked ? 0.5 : 1,
                child: SizedBox(
                  width: 68,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 10),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 30,
                        height: 16,
                        decoration: BoxDecoration(
                          color: on ? accentDim : const Color(0xFF2B2640),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: on ? accent : const Color(0xFF48416A)),
                        ),
                        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                        padding: const EdgeInsets.all(2),
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? accent : Pal.muted,
                            boxShadow: on ? [BoxShadow(color: accent, blurRadius: 8)] : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '${locked ? '\u{1F512}︎ ' : ''}${prettyName(p.name)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(11.5, color: Pal.muted, height: 1.1),
                      ),
                      Text(on ? 'on' : 'off', style: ui(12.5, color: changed ? accent : Pal.text, height: 1.2)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
