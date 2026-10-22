// The side column: the morph pad and My sounds (user presets). Port of tools/app/js/morph.js
// (drawing) and the preset list of app.js.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../morph_model.dart';
import '../theme.dart';
import 'chrome.dart';

class MorphPanel extends StatelessWidget {
  final AppController ctl;
  const MorphPanel(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final m = ctl.morph;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final filled = m.filled;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AreaHeadRow(
              'Morph',
              right: [
                Seg<MorphMode>(
                  value: m.mode,
                  onChanged: (v) {
                    m.setMode(v);
                    ctl.changed();
                  },
                  items: const [
                    (MorphMode.hand, 'Hand', 'Drag the puck'),
                    (MorphMode.orbit, 'Orbit', 'The puck circles on its own'),
                    (MorphMode.tilt, 'Tilt', 'Tilt the instrument to move the puck'),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AspectRatio(aspectRatio: 1 / 0.82, child: MorphPad(ctl)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = (math.min(420.0, c.maxWidth) - 6) / 2;
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (var k = 0; k < 4; k++) SizedBox(width: w, child: _CornerSlot(ctl, k, filled[k]))],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(m.hint, style: ui(12, color: Pal.faint)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  CheckLabel(
                    'Include effects',
                    value: m.includeFx,
                    onChanged: (v) {
                      m.includeFx = v;
                      ctl.changed();
                    },
                  ),
                  if (m.mode == MorphMode.orbit)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Speed', style: ui(12.5, color: Pal.muted)),
                        SizedBox(
                          width: 100,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(activeTrackColor: Pal.honey, thumbColor: Pal.honey),
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
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
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
    final col = rgb(cornerColors[k]);
    final name = c == null ? 'Empty' : (filled ? c.name : '${c.name} (other voice)');
    Widget act(String t, VoidCallback f) => MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: f,
        child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(t, style: ui(11.5, color: Pal.muted)),
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: Pal.panel2,
        border: Border.all(color: Pal.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Tooltip(
            message: 'Jump to this corner',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  m.goCorner(k);
                  ctl.changed();
                },
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? col : Colors.transparent,
                    border: Border.all(color: col, width: 2),
                  ),
                  child: Text(
                    cornerLetters[k],
                    style: ui(12, weight: FontWeight.w600, color: filled ? Pal.onHoney : col),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12.5, color: c != null && !filled ? Pal.faint : Pal.text),
                ),
                Row(
                  children: [
                    act(c != null ? 'Recapture' : 'Capture', () {
                      m.capture(k);
                      ctl.changed();
                    }),
                    if (c != null)
                      act('Clear', () {
                        m.clear(k);
                        ctl.changed();
                      }),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
  static const inset = 0.06;

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
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: const Color(0xFF18152A),
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
    final w0 = size.width, h0 = size.height;
    const inset = 0.06;
    final x0 = w0 * inset, y0 = h0 * inset, w = w0 * (1 - 2 * inset), h = h0 * (1 - 2 * inset);
    final filled = m.filled;
    final ready = m.ready;
    final weights = ready ? cornerWeights(m.u, m.v, filled) : const [0.0, 0.0, 0.0, 0.0];
    for (var k = 0; k < 4; k++) {
      if (!filled[k]) continue;
      final c = Offset(x0 + cornerPos[k].$1 * w, y0 + cornerPos[k].$2 * h);
      final col = rgb(cornerColors[k]);
      g.drawRect(
        Offset.zero & size,
        Paint()..shader = dui.Gradient.radial(c, math.max(w, h) * 0.95, [col.withValues(alpha: 0.1 + 0.4 * weights[k]), col.withValues(alpha: 0)]),
      );
    }
    final grid = Paint()
      ..color = const Color.fromRGBO(160, 150, 200, 0.12)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      g.drawLine(Offset(x0 + w * i / 4, y0), Offset(x0 + w * i / 4, y0 + h), grid);
      g.drawLine(Offset(x0, y0 + h * i / 4), Offset(x0 + w, y0 + h * i / 4), grid);
    }
    g.drawRect(
      Rect.fromLTWH(x0, y0, w, h),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color.fromRGBO(244, 210, 122, 0.22),
    );
    for (var k = 0; k < 4; k++) {
      g.drawCircle(
        Offset(x0 + cornerPos[k].$1 * w, y0 + cornerPos[k].$2 * h),
        filled[k] ? 5 + 6 * weights[k] : 3,
        Paint()..color = filled[k] ? rgb(cornerColors[k]) : const Color.fromRGBO(160, 150, 200, 0.35),
      );
    }
    if (!ready) return;
    final p = Offset(x0 + m.u * w, y0 + m.v * h);
    for (var k = 0; k < 4; k++) {
      if (!filled[k] || weights[k] < 0.02) continue;
      g.drawLine(
        p,
        Offset(x0 + cornerPos[k].$1 * w, y0 + cornerPos[k].$2 * h),
        Paint()
          ..color = rgb(cornerColors[k], 0.15 + 0.6 * weights[k])
          ..strokeWidth = 0.5 + 3 * weights[k],
      );
    }
    final tr = m.trail;
    for (var i = 1; i < tr.length; i++) {
      final f = i / tr.length;
      g.drawLine(
        Offset(x0 + tr[i - 1].$1 * w, y0 + tr[i - 1].$2 * h),
        Offset(x0 + tr[i].$1 * w, y0 + tr[i].$2 * h),
        Paint()
          ..color = Color.fromRGBO(255, 244, 220, f * 0.35)
          ..strokeWidth = 2.5 * f,
      );
    }
    var mix = [0.0, 0.0, 0.0];
    for (var k = 0; k < 4; k++) {
      if (!filled[k]) continue;
      final c = cornerColors[k];
      mix = [mix[0] + weights[k] * ((c >> 16) & 255), mix[1] + weights[k] * ((c >> 8) & 255), mix[2] + weights[k] * (c & 255)];
    }
    final mc = Color.fromRGBO(mix[0].round().clamp(0, 255), mix[1].round().clamp(0, 255), mix[2].round().clamp(0, 255), 1);
    g.drawCircle(p, 26, Paint()..shader = dui.Gradient.radial(p, 26, [mc.withValues(alpha: 0.55), mc.withValues(alpha: 0)]));
    g.drawCircle(p, 9, Paint()..color = mc);
    g.drawCircle(
      p,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFF8EA),
    );
  }

  @override
  bool shouldRepaint(covariant _MorphPainter old) => true;
}

// ---------------------------------------------------------------------------------------------
// My sounds

class PresetsPanel extends StatefulWidget {
  final AppController ctl;
  const PresetsPanel(this.ctl, {super.key});
  @override
  State<PresetsPanel> createState() => _PresetsPanelState();
}

class _PresetsPanelState extends State<PresetsPanel> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    widget.ctl.saveCurrent(_name.text);
    _name.clear();
  }

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
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AreaHead('My sounds', sub: 'saved on this computer'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      key: const Key('save-name'),
                      controller: _name,
                      maxLength: 48,
                      onSubmitted: (_) => _save(),
                      style: ui(14),
                      decoration: InputDecoration(
                        counterText: '',
                        isDense: true,
                        hintText: 'Name this sound',
                        hintStyle: ui(14, color: Pal.faint),
                        filled: true,
                        fillColor: Pal.ink,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Pal.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Pal.glacier),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Btn('Save', key: const Key('btn-save-sound'), onPressed: _save),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                if (ctl.presets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Text(
                      'Shape a sound, name it and save it. It stays on this computer; export to keep a file.',
                      style: ui(11.5, color: Pal.faint),
                    ),
                  ),
                for (final p in ctl.presets) _PresetRow(ctl, p),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Wrap(
              spacing: 6,
              children: [
                Btn('Export all', small: true, onPressed: _export),
                Btn('Import', small: true, onPressed: _import),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetRow extends StatefulWidget {
  final AppController ctl;
  final Preset p;
  const _PresetRow(this.ctl, this.p);
  @override
  State<_PresetRow> createState() => _PresetRowState();
}

class _PresetRowState extends State<_PresetRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.p, ctl = widget.ctl;
    final d = DateTime.tryParse(p.created)?.toLocal();
    final date = d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: _hover ? Pal.panel2 : null, borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: 'Recall "${p.name}" (${p.voice})',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => ctl.recallPreset(p),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(14, weight: FontWeight.w600),
                        ),
                        Text('${p.voice}, $date', style: ui(11.5, color: Pal.faint)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Visibility(
              visible: _hover,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Row(
                children: [
                  Btn('C', kind: BtnKind.quiet, small: true, tooltip: 'Copy as C', onPressed: () => showCode(context, ctl, p)),
                  Btn('Delete', kind: BtnKind.quiet, small: true, tooltip: 'Delete', onPressed: () => ctl.deletePreset(p)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
