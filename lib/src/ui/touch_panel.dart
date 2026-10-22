// Touch: the whole-instrument sensitivity (target 2), the key equalizer (target 3) with the live
// pressure meter and Suggest, and Save to Striso. Port of the touch parts of tools/app/js.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'paint_util.dart';

class _TouchInfo {
  final String label, help;
  final bool log;
  final double def;
  final double? step;
  const _TouchInfo(this.label, this.log, this.def, this.help, [this.step]);
}

const _touchInfo = {
  'pressure': _TouchInfo('Pressure', true, 1, 'How much pressure the synth sees for the same force. Raise it if playing feels too stiff.'),
  'velocity': _TouchInfo('Velocity', true, 1, 'How much the speed of a strike counts. Raise it if strikes all sound alike.'),
  'tilt': _TouchInfo('Tilt', false, 1, 'How much rocking a key forward and back shapes the sound. Negative turns the direction around.'),
  'bend': _TouchInfo('Bend', false, 0.5, 'How far rocking a key sideways bends its pitch. 0 turns bending off.'),
  'threshold': _TouchInfo(
    'Threshold',
    false,
    0,
    'How light a touch starts a note. Lower starts notes with a lighter touch; too low and notes may start by themselves.',
    0.001,
  ),
};

Widget _h3(String t) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Text(t, style: ui(13.5, weight: FontWeight.w600)),
);
Widget _help(String t) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Text(t, style: ui(12, color: Pal.faint, height: 1.4)),
);

class TouchGlobal extends StatelessWidget {
  final AppController ctl;
  const TouchGlobal(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final list = ctl.params[2]!.params;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _h3('Whole instrument'),
            for (final p in list) _TouchRow(ctl, p),
            if (list.isEmpty)
              Text(
                !ctl.connected
                    ? 'Connect to see the touch settings.'
                    : ctl.listsLoading
                    ? 'Reading the parameters from the board…'
                    : 'This firmware has no live touch settings: update the Striso firmware.',
                style: ui(13, color: Pal.faint),
              ),
          ],
        );
      },
    );
  }
}

class _TouchRow extends StatefulWidget {
  final AppController ctl;
  final Param p;
  const _TouchRow(this.ctl, this.p);
  @override
  State<_TouchRow> createState() => _TouchRowState();
}

class _TouchRowState extends State<_TouchRow> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p, ctl = widget.ctl;
    final info = _touchInfo[p.name] ?? _TouchInfo(p.name, false, p.loadValue, '');
    final log = info.log && p.min > 0;
    double toPos(double v) => log ? math.log(v) : v;
    double fromPos(double x) => log ? math.exp(x) : x;
    String fmt(double v) => v.toStringAsFixed(p.max - p.min <= 1 ? 3 : 2);
    final key = 'touch:${p.index}';
    return ListenableBuilder(
      listenable: ctl.values,
      builder: (context, _) {
        final changed = (p.value - info.def).abs() > 1e-6;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(width: 82, child: Text(info.label, style: ui(13))),
                  Expanded(
                    child: Tooltip(
                      message:
                          '${info.label}: ${fmtNum(p.min)} to ${fmtNum(p.max)}, default ${fmtNum(info.def)}. Double-click resets to ${fmtNum(info.def)}.',
                      waitDuration: const Duration(milliseconds: 900),
                      child: GestureDetector(
                        onDoubleTap: () {
                          ctl.onEdit(2, p, info.def, 'begin', 'Reset ${info.label.toLowerCase()}');
                          ctl.onEdit(2, p, info.def, 'end');
                        },
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(activeTrackColor: Pal.glacier, thumbColor: Pal.glacier),
                          child: Slider(
                            value: toPos(p.value).clamp(toPos(p.min), toPos(p.max)),
                            min: toPos(p.min),
                            max: toPos(p.max),
                            onChanged: (x) {
                              final v = conformValue(p, fromPos(x));
                              if (!_active) {
                                _active = true;
                                ctl.onEdit(2, p, v, 'begin', 'Touch ${info.label.toLowerCase()}', key);
                              } else {
                                ctl.onEdit(2, p, v, 'change');
                              }
                            },
                            onChangeEnd: (_) {
                              _active = false;
                              ctl.onEdit(2, p, p.value, 'end');
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 54,
                    child: Text(
                      fmt(p.value),
                      textAlign: TextAlign.right,
                      style: ui(13, color: changed ? Pal.glacier : Pal.muted),
                    ),
                  ),
                ],
              ),
              if (info.help.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 92),
                  child: Text(info.help, style: ui(12, color: Pal.faint, height: 1.4)),
                ),
            ],
          ),
        );
      },
    );
  }
}

String fmtNum(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class KeyEqualizer extends StatelessWidget {
  final AppController ctl;
  const KeyEqualizer(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl, ctl.values]),
      builder: (context, _) {
        final has = ctl.params[3]!.params.isNotEmpty;
        final sel = ctl.eqSelected;
        final p = sel >= 0 ? ctl.keyParam(sel) : null;
        final live = ctl.live;
        String name, meta;
        if (!has) {
          name = 'No key factors';
          meta = ctl.connected ? 'This firmware has no per-key sensitivity: update the Striso firmware.' : 'Connect to adjust the keys.';
        } else if (p == null) {
          name = 'No key selected';
          meta = 'Click a key on the board, or press one.';
        } else {
          name = noteName(sel, live.transpose, live.transposeFifths).full;
          final pk = ctl.lastPeakOf(sel);
          final med = ctl.eqMedian;
          meta = 'key ${p.index} (${p.name} in the settings)';
          if (pk > 0) {
            meta += ', last press ${pk >= 1.7 ? 'at the maximum' : pk.toStringAsFixed(2)}';
            if (med != null && pk < 1.7) {
              final d = ((pk / med - 1) * 100).round();
              meta += d == 0 ? ', right at the middle' : ', ${d.abs()}% ${d > 0 ? 'above' : 'below'} the middle ${med.toStringAsFixed(2)}';
            }
          }
        }
        final ms = ctl.measuredKeys();
        final med = ctl.computeEqMedian(ms);
        final status = !has
            ? ''
            : ms.isNotEmpty
            ? '${ms.length} key${ms.length == 1 ? '' : 's'} measured${med != null ? ', middle peak ${med.toStringAsFixed(2)}' : ''}. Suggest evens out the measured keys only.'
            : 'No presses measured yet: press keys one after another with the same feel.';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _h3('Key equalizer'),
            _help(
              'Press keys one after another with the same feel. Each key shows the peak pressure of its last press '
              '(green near the middle, blue low, warm high) and its factor. Even them out by hand, or press a set of keys evenly and let Suggest do it.',
            ),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                CheckLabel('Show on the board', value: ctl.eqOn, onChanged: ctl.setEqOn),
                CheckLabel('Select the last pressed key', value: ctl.eqFollow, onChanged: ctl.setEqFollow),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: Pal.panel2,
                border: Border.all(color: Pal.line),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    key: const Key('eq-keyname'),
                    style: ui(24, color: Pal.glacier, weight: FontWeight.w600, height: 1.1),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(meta, style: ui(12.5, color: Pal.muted)),
                  ),
                  SizedBox(height: 84, child: KeyMeter(ctl)),
                  const SizedBox(height: 4),
                  _MeterText(ctl),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Btn('−5%', small: true, onPressed: p == null ? null : () => ctl.eqStep(0.95)),
                      const SizedBox(width: 6),
                      Btn('−2%', small: true, onPressed: p == null ? null : () => ctl.eqStep(0.98)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(activeTrackColor: Pal.glacier, thumbColor: Pal.glacier),
                          child: _FactorSlider(ctl, p),
                        ),
                      ),
                      Btn('+2%', small: true, onPressed: p == null ? null : () => ctl.eqStep(1.02)),
                      const SizedBox(width: 6),
                      Btn('+5%', small: true, onPressed: p == null ? null : () => ctl.eqStep(1.05)),
                      SizedBox(
                        width: 74,
                        child: Text(
                          p != null ? '×${p.value.toStringAsFixed(2)}' : '',
                          textAlign: TextAlign.right,
                          style: ui(18, weight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(status, style: ui(12.5, color: Pal.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Btn('Suggest', key: const Key('eq-suggest'), small: true, onPressed: has ? () => _suggest(context) : null),
                Btn('Clear readings', small: true, onPressed: has ? ctl.eqClear : null),
                Btn('Reset key', small: true, onPressed: p != null ? ctl.eqResetKey : null),
                Btn('Reset all keys', small: true, onPressed: has ? ctl.eqResetAll : null),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _suggest(BuildContext context) async {
    final r = ctl.eqSuggest();
    if (r == null) return;
    if (await showSuggest(context, r)) ctl.eqApply(r);
  }
}

class _FactorSlider extends StatefulWidget {
  final AppController ctl;
  final Param? p;
  const _FactorSlider(this.ctl, this.p);
  @override
  State<_FactorSlider> createState() => _FactorSliderState();
}

class _FactorSliderState extends State<_FactorSlider> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final pos = p == null ? 0.0 : (math.log(p.value) / math.ln2).clamp(-2.0, 2.0);
    return Slider(
      key: const Key('eq-factor'),
      value: pos,
      min: -2,
      max: 2,
      onChanged: p == null
          ? null
          : (x) {
              widget.ctl.eqSetFactor(math.pow(2, x).toDouble(), _active ? 'change' : 'begin');
              _active = true;
            },
      onChangeEnd: p == null
          ? null
          : (_) {
              _active = false;
              widget.ctl.onEdit(3, p, p.value, 'end');
            },
    );
  }
}

class _MeterText extends StatelessWidget {
  final AppController ctl;
  const _MeterText(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.stats,
      builder: (context, _) {
        final id = ctl.eqSelected;
        final p = id >= 0 ? ctl.keyParam(id) : null;
        if (p == null) {
          return SizedBox(
            height: 34,
            child: Text('The pressure of the selected key shows here, live, while you hold it.', style: ui(12, color: Pal.faint, height: 1.4)),
          );
        }
        final live = ctl.live;
        final down = live.down[id] == 1;
        final value = down ? live.raw[id].toDouble() : 0.0, hold = down ? live.peak[id].toDouble() : 0.0, last = ctl.lastPeakOf(id);
        final sens = ctl.findParam(2, 'pressure')?.value ?? 1.0;
        String f(double v) => v >= 1.7 ? 'max' : v.toStringAsFixed(2);
        final seen = value > 0 ? value : last;
        return SizedBox(
          height: 34,
          child: Text.rich(
            TextSpan(
              style: ui(12, color: Pal.faint, height: 1.4),
              children: [
                TextSpan(
                  text: '${f(value)} now${hold > 0 ? ', peak ${f(hold)}' : ''}${last > 0 ? ', last press ${f(last)}' : ''}',
                  style: ui(13.5, weight: FontWeight.w600),
                ),
                TextSpan(
                  text:
                      " Measured after this key's factor ×${p.value.toStringAsFixed(2)}; the synth multiplies it by Pressure ×${sens.toStringAsFixed(2)}"
                      '${seen > 0 ? ' (${f(seen * sens)}).' : '.'}',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bar: the pressure now, a white tick for the peak of this press, a dashed tick for the last
/// finished press. Trace: the last 2 s, with the middle of the measured keys as a dotted line.
/// The scale only grows (until Clear readings), so presses on different keys compare by eye.
class KeyMeter extends StatefulWidget {
  final AppController ctl;
  const KeyMeter(this.ctl, {super.key});
  @override
  State<KeyMeter> createState() => _KeyMeterState();
}

class _KeyMeterState extends State<KeyMeter> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final trace = PressureTrace();
  final _repaint = Pulse();
  double scale = 0.5, quietSince = -1e9;
  int id = -2, _reset = 0;
  bool force = true;
  ({double value, double hold, double last, double median}) s = (value: 0, hold: 0, last: 0, median: 0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _frame())..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _frame() {
    final ctl = widget.ctl;
    final now = clockMs();
    if (ctl.eqMeterReset != _reset) {
      _reset = ctl.eqMeterReset;
      scale = 0.5;
      force = true;
    }
    final sel = ctl.eqSelected;
    final p = sel >= 0 ? ctl.keyParam(sel) : null;
    final kid = p != null ? sel : -1;
    final live = ctl.live;
    final down = kid >= 0 && live.down[kid] == 1;
    s = (
      value: down ? live.raw[kid].toDouble() : 0.0,
      hold: down ? live.peak[kid].toDouble() : 0.0,
      last: kid >= 0 ? ctl.lastPeakOf(kid) : 0.0,
      median: ctl.eqMedian ?? 0.0,
    );
    if (kid != id) {
      id = kid;
      trace.reset();
      force = true;
    }
    if (kid >= 0) trace.push(now, s.value);
    final active = s.value > 0 || now - quietSince < trace.window + 100;
    if (s.value > 0) quietSince = now;
    if (!active && !force) return;
    force = false;
    final top = [s.value, s.hold, s.last, s.median, trace.max(now)].reduce(math.max);
    while (top > scale * 0.92) {
      scale = ((scale * 1.25) * 10).round() / 10;
    }
    _repaint.ping();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Live pressure of the selected key: bar, peak of this press, last press, and the last two seconds',
    child: CustomPaint(painter: _MeterPainter(this, _repaint), size: Size.infinite),
  );
}

class _MeterPainter extends CustomPainter {
  final _KeyMeterState m;
  _MeterPainter(this.m, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas g, Size size) {
    final w = size.width, h = size.height;
    final now = clockMs();
    final s = m.s;
    double x(double v) => math.min(w, (v / m.scale) * w);
    const bh = 14.0;
    g.drawRect(Rect.fromLTWH(0, 0, w, bh), Paint()..color = const Color.fromRGBO(160, 150, 200, 0.14));
    if (m.id >= 0 && s.value > 0) {
      g.drawRect(
        Rect.fromLTWH(0, 0, x(s.value), bh),
        Paint()
          ..shader = LinearGradient(
            colors: const [Color(0xFFF4D27A), Color(0xFFFF9654), Color(0xFFFF6270)],
            stops: const [0, 0.6, 1],
          ).createShader(Rect.fromLTWH(0, 0, w, bh)),
      );
    }
    void tick(double v, Color c, bool dash) {
      if (!(v > 0)) return;
      final p = Paint()
        ..color = c
        ..strokeWidth = 2;
      if (dash) {
        dashedLine(g, Offset(x(v), -1), Offset(x(v), bh + 3), p, 3, 2);
      } else {
        g.drawLine(Offset(x(v), -1), Offset(x(v), bh + 3), p);
      }
    }

    tick(s.last, Pal.glacier, true);
    tick(s.hold, Colors.white, false);
    const ty = bh + 8;
    final th = h - ty - 2;
    double y(double v) => ty + th - math.min(1, v / m.scale) * th;
    g.drawRect(Rect.fromLTWH(0, ty, w, th), Paint()..color = const Color.fromRGBO(160, 150, 200, 0.07));
    void hline(double v, Color c, double dash, double gap) {
      if (!(v > 0)) return;
      dashedLine(
        g,
        Offset(0, y(v)),
        Offset(w, y(v)),
        Paint()
          ..color = c
          ..strokeWidth = 1,
        dash,
        gap,
      );
    }

    hline(s.median, const Color.fromRGBO(143, 227, 164, 0.7), 2, 3);
    hline(s.last, const Color.fromRGBO(143, 220, 236, 0.6), 5, 3);
    final pts = m.trace.points(now);
    if (pts.length > 1) {
      double tx(double t) => w - ((now - t) / m.trace.window) * w;
      final area = Path()..moveTo(tx(pts.first.$1), ty + th);
      for (final (t, v) in pts) {
        area.lineTo(tx(t), y(v));
      }
      area
        ..lineTo(tx(pts.last.$1), ty + th)
        ..close();
      g.drawPath(area, Paint()..color = const Color.fromRGBO(244, 210, 122, 0.18));
      final line = Path();
      for (final (i, (t, v)) in pts.indexed) {
        i == 0 ? line.moveTo(tx(t), y(v)) : line.lineTo(tx(t), y(v));
      }
      g.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Pal.honey,
      );
    }
    drawText(
      g,
      m.scale.toStringAsFixed(1),
      Offset(w - 3, ty + 2),
      10,
      const Color.fromRGBO(200, 192, 225, 0.55),
      weight: FontWeight.w400,
      align: 1,
      vAlign: -1,
    );
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) => true;
}

class SaveBox extends StatelessWidget {
  final AppController ctl;
  const SaveBox(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final st = ctl.saveStatus;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _h3('Keep these settings'),
            _help(
              "Changes here last until the Striso is switched off. Save writes them to the board's settings; it restarts, which takes about "
              '15 seconds. Switching the Striso on while holding the glissando button still starts it with the factory settings.',
            ),
            Btn('Save to Striso', key: const Key('btn-save-board'), kind: BtnKind.primary, onPressed: ctl.saving ? null : () => _save(context)),
            const SizedBox(height: 10),
            SelectableText(
              st.text,
              key: const Key('save-status'),
              style: ui(12.5, color: st.cls == 'err' ? Pal.danger : (st.cls == 'ok' ? Pal.ok : Pal.muted)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save(BuildContext context) async {
    if (ctl.canSave() != null) return;
    if (await confirmSave(context)) await ctl.doSave();
  }
}
