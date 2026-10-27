// Setup (DESIGN.md 3): a mode control (Sensitivity, Key equalizer, Settings keys) changes the
// board's overlay and the right column; Save to Striso, Audio (Through PC, devices, Record), the
// motion sensor, the firmware that plays and its engine slots are always at the lower right. The firmware builds
// Virtual can run are chosen from the header's Virtual control (docs/flows.md 5), not here.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'audio.dart';
import 'board_view.dart';
import 'chrome.dart';
import 'engine_slots.dart';
import 'live_panel.dart';
import 'paint_util.dart';
import 'play_tab.dart';

class SetupTab extends StatelessWidget {
  final AppController ctl;
  const SetupTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => LayoutBuilder(
        builder: (context, c) {
          final right = c.maxWidth >= 1200 ? Sizes.setupRight : 300.0;
          final board = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: Sizes.toolbar,
                child: Row(
                  children: [
                    Seg<SetupMode>(
                      value: ctl.setupMode,
                      onChanged: ctl.setSetupMode,
                      keys: const {
                        SetupMode.sensitivity: Key('mode-sensitivity'),
                        SetupMode.equalizer: Key('eq-on'),
                        SetupMode.settings: Key('btn-settings-overlay'),
                      },
                      items: const [
                        (SetupMode.sensitivity, 'Sensitivity', 'Touch sensitivity of the whole instrument'),
                        (SetupMode.equalizer, 'Key equalizer', 'Each key’s sensitivity factor and its last press'),
                        (SetupMode.settings, 'Settings keys', 'What each key does with the Settings button held (S)'),
                      ],
                    ),
                    const Spacer(),
                    SmallSelect<Names>(
                      value: ctl.names,
                      items: [for (final (n, l) in PlayToolbar.names) (n, l.split('  ').first)],
                      onChanged: ctl.setNames,
                    ),
                  ],
                ),
              ),
              Expanded(child: BoardStage(ctl, overlays: true)),
              SizedBox(
                height: Sizes.toolbar,
                child: Align(alignment: Alignment.centerLeft, child: HoverReadout(ctl)),
              ),
            ],
          );
          final column = SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Sizes.toolbar),
                switch (ctl.setupMode) {
                  SetupMode.sensitivity => Sensitivity(ctl),
                  SetupMode.equalizer => KeyEqualizer(ctl),
                  SetupMode.settings => SettingsInfo(ctl),
                },
                const SizedBox(height: Space.xxl),
                SaveBox(ctl),
                const SizedBox(height: Space.xxl),
                AudioSection(ctl),
                const SizedBox(height: Space.xl),
                MidiOutSection(ctl),
                const SizedBox(height: Space.xl),
                if (c.maxWidth >= 1100) ...[MotionRow(ctl), const SizedBox(height: Space.l), FirmwareRow(ctl)],
                const SizedBox(height: Space.xl),
                EngineSlots(ctl),
                const SizedBox(height: Space.m),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Btn('Console ▸', kind: BtnKind.ghost, onPressed: () => ctl.setConsole(true)),
                ),
                const SizedBox(height: Space.l),
              ],
            ),
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: board),
                      if (c.maxWidth < 1100)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.s),
                          child: Row(
                            children: [
                              Expanded(child: MotionRow(ctl)),
                              const SizedBox(width: Space.xl),
                              Expanded(child: FirmwareRow(ctl)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.column),
                SizedBox(width: right, child: column),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// sensitivity

class _TouchInfo {
  final String label, help;
  final bool log;
  final double def;
  const _TouchInfo(this.label, this.log, this.def, this.help);
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
    'How light a touch starts a note. Lower starts notes lighter; too low and notes may start by themselves.',
  ),
};

class Sensitivity extends StatelessWidget {
  final AppController ctl;
  const Sensitivity(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final list = ctl.params[2]!.params;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Micro('Sensitivity'),
        const SizedBox(height: Space.s),
        for (final p in list) _TouchRow(ctl, p),
        if (list.isEmpty)
          EmptyNote(
            !ctl.connected
                ? 'Connect to see the touch settings.'
                : ctl.listsLoading
                ? 'Reading the parameters from the board…'
                : 'This firmware has no live touch settings: update the Striso firmware.',
          )
        else ...[
          const SizedBox(height: Space.s),
          Text('Changes are live. Save to keep them.', style: ui(TypeSize.small, color: Pal.text3)),
        ],
      ],
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
    void set(double v, String phase, [String? label]) => ctl.onEdit(2, p, v, phase, label, 'touch:${p.index}');
    return ListenableBuilder(
      listenable: ctl.values,
      builder: (context, _) {
        final changed = (p.value - info.def).abs() > 1e-6;
        return Tooltip(
          message: info.help,
          waitDuration: const Duration(milliseconds: 700),
          child: SizedBox(
            height: Sizes.row + 4,
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(info.label, style: ui(TypeSize.body, color: Pal.text2)),
                ),
                Expanded(
                  child: Slider(
                    value: toPos(p.value).clamp(toPos(p.min), toPos(p.max)),
                    min: toPos(p.min),
                    max: toPos(p.max),
                    onChanged: (x) {
                      final v = conformValue(p, fromPos(x));
                      if (!_active) {
                        _active = true;
                        set(v, 'begin', 'Touch ${info.label.toLowerCase()}');
                      } else {
                        set(v, 'change');
                      }
                    },
                    onChangeEnd: (_) {
                      _active = false;
                      set(p.value, 'end');
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    fmt(p.value),
                    textAlign: TextAlign.right,
                    // sent, not yet read back from the board
                    style: ui(TypeSize.body, color: ctl.sound.isPending(2, p) ? Pal.text3 : Pal.text1),
                  ),
                ),
                SizedBox(
                  width: Sizes.control,
                  child: changed
                      ? IconBtn(
                          Icons.replay,
                          tooltip: 'Back to ${info.def}',
                          onPressed: () {
                            set(info.def, 'begin', 'Reset ${info.label.toLowerCase()}');
                            set(info.def, 'end');
                          },
                        )
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// key equalizer

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
              meta += d == 0 ? ', at the middle' : ', ${d.abs()}% ${d > 0 ? 'above' : 'below'} the middle ${med.toStringAsFixed(2)}';
            }
          }
        }
        final ms = ctl.measuredKeys();
        final med = ctl.computeEqMedian(ms);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.l,
              runSpacing: Space.xs,
              children: [
                const Micro('Key equalizer'),
                Toggle(value: ctl.eqFollow, label: 'Follow presses', onChanged: ctl.setEqFollow),
              ],
            ),
            const SizedBox(height: Space.m),
            Text(
              name,
              key: const Key('eq-keyname'),
              style: ui(TypeSize.sound, weight: FontWeight.w500),
            ),
            Text(meta, style: ui(TypeSize.small, color: Pal.text2)),
            const SizedBox(height: Space.m),
            Row(
              children: [
                IconBtn(Icons.remove, tooltip: '÷ 2%', onPressed: p == null ? null : () => ctl.eqStep(0.98)),
                Expanded(child: _FactorSlider(ctl, p)),
                IconBtn(Icons.add, tooltip: '× 2%', onPressed: p == null ? null : () => ctl.eqStep(1.02)),
                SizedBox(
                  width: 56,
                  child: Text(p != null ? '×${p.value.toStringAsFixed(2)}' : '', textAlign: TextAlign.right, style: ui(TypeSize.body)),
                ),
              ],
            ),
            const SizedBox(height: Space.s),
            SizedBox(width: 300, height: 60, child: KeyMeter(ctl)),
            const SizedBox(height: Space.xs),
            _MeterText(ctl),
            const SizedBox(height: Space.m),
            Text(
              !has
                  ? ''
                  : ms.isNotEmpty
                  ? '${ms.length} key${ms.length == 1 ? '' : 's'} measured${med != null ? ', middle peak ${med.toStringAsFixed(2)}' : ''}.'
                  : 'Press keys one after another with the same feel.',
              style: ui(TypeSize.small, color: Pal.text2),
            ),
            const SizedBox(height: Space.s),
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                Btn('Suggest', key: const Key('eq-suggest'), tooltip: 'Even out the measured keys', onPressed: has ? () => _suggest(context) : null),
                Btn('Reset key', kind: BtnKind.ghost, onPressed: p != null ? ctl.eqResetKey : null),
                Btn('Reset all', kind: BtnKind.ghost, onPressed: has ? ctl.eqResetAll : null),
                Btn('Clear measurements', kind: BtnKind.ghost, onPressed: has ? ctl.eqClear : null),
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
    // x0.50 .. x2.00 on a log scale
    final pos = p == null ? 0.0 : (math.log(p.value) / math.ln2).clamp(-1.0, 1.0);
    return Slider(
      key: const Key('eq-factor'),
      value: pos,
      min: -1,
      max: 1,
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
        if (p == null) return Text('The selected key’s pressure shows here while you hold it.', style: ui(TypeSize.small, color: Pal.text3));
        final live = ctl.live;
        final down = live.down[id] == 1;
        final value = down ? live.raw[id].toDouble() : 0.0, hold = down ? live.peak[id].toDouble() : 0.0, last = ctl.lastPeakOf(id);
        final sens = ctl.findParam(2, 'pressure')?.value ?? 1.0;
        String f(double v) => v >= 1.7 ? 'max' : v.toStringAsFixed(2);
        return Tooltip(
          message:
              "Measured after this key's factor ×${p.value.toStringAsFixed(2)}; the synth multiplies it by Pressure ×${sens.toStringAsFixed(2)}.",
          child: Text(
            '${f(value)} now${hold > 0 ? ' · peak ${f(hold)}' : ''}${last > 0 ? ' · last press ${f(last)}' : ''}',
            style: ui(TypeSize.small, color: Pal.text2),
          ),
        );
      },
    );
  }
}

/// The selected key's pressure: a bar with the peak and last press ticks, and the last two
/// seconds as a trace with the middle of the measured keys. The scale only grows until Clear.
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
    final kid = sel >= 0 && ctl.keyParam(sel) != null ? sel : -1;
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
    label: 'Live pressure of the selected key',
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
    const bh = 6.0;
    g.drawRRect(RRect.fromLTRBR(0, 0, w, bh, const Radius.circular(3)), Paint()..color = Pal.bg3);
    if (m.id >= 0 && s.value > 0) {
      g.drawRRect(RRect.fromLTRBR(0, 0, x(s.value), bh, const Radius.circular(3)), Paint()..color = Pal.accent);
    }
    void tick(double v, Color c) {
      if (!(v > 0)) return;
      g.drawLine(
        Offset(x(v), -2),
        Offset(x(v), bh + 2),
        Paint()
          ..color = c
          ..strokeWidth = 2,
      );
    }

    tick(s.last, Pal.text2);
    tick(s.hold, Pal.text1);
    const ty = bh + 6;
    final th = h - ty;
    double y(double v) => ty + th - math.min(1, v / m.scale) * th;
    if (s.median > 0) {
      dashedLine(
        g,
        Offset(0, y(s.median)),
        Offset(w, y(s.median)),
        Paint()
          ..color = Pal.ok.withValues(alpha: 0.7)
          ..strokeWidth = 1,
        2,
        3,
      );
    }
    final pts = m.trace.points(now);
    if (pts.length > 1) {
      double tx(double t) => w - ((now - t) / m.trace.window) * w;
      final line = Path();
      for (final (i, (t, v)) in pts.indexed) {
        i == 0 ? line.moveTo(tx(t), y(v)) : line.lineTo(tx(t), y(v));
      }
      g.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Pal.accent,
      );
    }
    drawText(g, m.scale.toStringAsFixed(1), Offset(w, ty), TypeSize.micro, Pal.text3, weight: FontWeight.w400, align: 1, vAlign: -1);
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) => true;
}

// ---------------------------------------------------------------------------------------------
// save, motion, firmware

class SaveBox extends StatelessWidget {
  final AppController ctl;
  const SaveBox(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final st = ctl.saveStatus;
    final reason = !ctl.connected
        ? 'Nothing plays: connect the Striso or play Virtual first'
        : (ctl.params[2]!.params.isEmpty && ctl.params[3]!.params.isEmpty)
        ? 'This firmware has no touch settings to save'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Btn(
          'Save to ${ctl.caps?.short ?? 'Striso'}',
          key: const Key('btn-save-board'),
          kind: BtnKind.primary,
          tooltip:
              reason ??
              (ctl.caps?.keptHere == true
                  ? 'Writes the touch settings and key factors to ${ctl.caps!.name}\u2019s settings, kept on this computer (it restarts)'
                  : 'Writes the touch settings and key factors to the board (it restarts, about 15 s)'),
          onPressed: ctl.saving || reason != null ? null : () => _save(context),
        ),
        if (ctl.saving)
          const Padding(
            padding: EdgeInsets.only(top: Space.s),
            child: SizedBox(
              width: 160,
              child: LinearProgressIndicator(minHeight: 2, color: Pal.accent, backgroundColor: Pal.bg3),
            ),
          ),
        if (st.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: SelectableText(
              st.text,
              key: const Key('save-status'),
              style: ui(TypeSize.small, color: st.cls == 'err' ? Pal.error : (st.cls == 'ok' ? Pal.ok : Pal.text2)),
            ),
          ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    if (ctl.canSave() != null) return;
    if (await confirmSave(context)) await ctl.doSave();
  }
}

class MotionRow extends StatelessWidget {
  final AppController ctl;
  const MotionRow(this.ctl, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Micro('Motion'),
      const SizedBox(height: Space.s),
      SizedBox(height: 72, child: MotionView(ctl)),
    ],
  );
}

/// MIDI out as the board has it (StcY): its mode, the channels and the bend range, the volume,
/// sustain and message rate; the mode switched with its settings keys (StcX's MIDI switches,
/// pressed over USB and read back). The dials are set on the instrument.
class MidiOutSection extends StatelessWidget {
  final AppController ctl;
  const MidiOutSection(this.ctl, {super.key});
  @override
  Widget build(BuildContext context) {
    final st = ctl.boardState;
    final modes = [
      for (final e in ctl.settingsLayout.keys.entries)
        if (e.value.group == SettingsGroup.midi && e.value.switchable) e,
    ];
    final mode = st?.midi;
    final current = st?.midiKey ?? -1; // the key the board reports for its mode (StcY midikey=)
    String? channels;
    if (st != null) {
      final ch = st.channel, n = st.voices, bend = st.bend;
      channels = [
        if (mode == 'mpe' && n != null && ch != null) '$n voices from channel $ch' else if (ch != null) 'channel $ch',
        if (mode == 'mpe' && bend != null) 'pitch bend $bend semitones',
      ].join(' · ');
    }
    final rest = st == null
        ? null
        : [
            if (st.volume != null) 'volume ${st.volume}',
            if (st.sustain != null) 'sustain ${st.sustain!.toStringAsFixed(2)}',
            if (st.rate != null) 'a message every ${st.rate} ms',
          ].join(' · ');
    return Column(
      key: const Key('midi-out'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Micro('MIDI out'),
        const SizedBox(height: Space.xs),
        if (st == null || modes.isEmpty)
          Text(ctl.connected ? 'This firmware does not report its MIDI settings.' : 'Connect to see the board\'s MIDI settings.', style: ui(TypeSize.body, color: Pal.text2))
        else ...[
          Seg<int>(
            items: [for (final e in modes) (e.key, e.value.short, e.value.title)],
            value: current,
            keys: {for (final e in modes) e.key: Key('midi-mode-${e.key}')},
            onChanged: (k) => k == current ? null : ctl.pressSettingsKey(k),
          ),
          if (ctl.dials != null && ctl.dials!.isNotEmpty) ...[
            const SizedBox(height: Space.s),
            for (final d in ctl.dials!) _DialRow(ctl, d),
          ] else if (channels != null && channels.isNotEmpty) ...[
            const SizedBox(height: Space.xs),
            Text('${modes.where((e) => e.key == current).map((e) => e.value.short).firstOrNull ?? mode} · $channels', key: const Key('midi-out-channels'), style: ui(TypeSize.body)),
          ],
          if (ctl.dials == null || ctl.dials!.isEmpty) ...[
            if (rest != null && rest.isNotEmpty) Text(rest, key: const Key('midi-out-rest'), style: ui(TypeSize.body, color: Pal.text2)),
            Text('The channels, bend range, volume and rate are dials: Settings + tilt on the instrument.', style: ui(TypeSize.small, color: Pal.text3)),
          ],
        ],
      ],
    );
  }
}

/// A settings dial as a slider in the board's range and steps (StcT's list): its value is the
/// board's (StcY); a drag sends the value at its end (StcT) and shows what the board took.

class _DialRow extends StatefulWidget {
  final AppController ctl;
  final DialInfo d;
  const _DialRow(this.ctl, this.d);
  @override
  State<_DialRow> createState() => _DialRowState();
}

/// How the dials read (the board names them by their StcY fields).
const _dialLabels = {'ch': 'Channel', 'voices': 'MPE voices', 'bend': 'Bend range', 'vol': 'Volume', 'sustain': 'Sustain', 'rate': 'Rate', 'fine': 'Fine tune'};
const _dialUnits = {'bend': ' st', 'rate': ' ms', 'fine': ' ¢'};

class _DialRowState extends State<_DialRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final d = widget.d, ctl = widget.ctl;
    final values = d.values;
    final board = ctl.dialValue(d);
    // a slider's position: the value itself, or its index among the dial's values
    double pos(double v) => values == null ? v.clamp(d.min, d.max) : values.indexWhere((x) => x >= v - 1e-6).clamp(0, values.length - 1).toDouble();
    double valueAt(double p) => values == null ? p : values[p.round().clamp(0, values.length - 1)];
    final shown = _drag ?? board;
    final decimals = d.step > 0 && d.step < 1 ? 3 : (d.step % 1 != 0 ? 2 : 0);
    final text = shown == null ? '–' : '${shown.toStringAsFixed(decimals)}${_dialUnits[d.name] ?? ''}';
    return SizedBox(
      height: Sizes.row + 4,
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(_dialLabels[d.name] ?? d.name, style: ui(TypeSize.body, color: Pal.text2)),
          ),
          Expanded(
            child: Slider(
              key: Key('dial-${d.name}'),
              value: shown == null ? (values == null ? d.min : 0) : pos(shown),
              min: values == null ? d.min : 0,
              max: values == null ? d.max : (values.length - 1).toDouble(),
              divisions: d.divisions,
              onChanged: board == null || !ctl.canSend ? null : (p) => setState(() => _drag = valueAt(p)),
              onChangeEnd: (p) async {
                await ctl.setDial(d, valueAt(p));
                if (mounted) setState(() => _drag = null);
              },
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(text, key: Key('dial-${d.name}-value'), textAlign: TextAlign.right, style: ui(TypeSize.body, color: _drag != null ? Pal.text3 : Pal.text1)),
          ),
        ],
      ),
    );
  }
}

/// The firmware that plays: the Striso's version, or Virtual's build (its title and the version
/// it reports), with a copy button. The builds are chosen in Play.
class FirmwareRow extends StatelessWidget {
  final AppController ctl;
  const FirmwareRow(this.ctl, {super.key});
  @override
  Widget build(BuildContext context) {
    final v = ctl.version;
    final virtual = ctl.connected && ctl.virtual.instrument != null;
    final text = v == null
        ? (ctl.connected ? 'The board did not report its version.' : 'Nothing plays')
        : virtual
        ? '${ctl.virtual.buildTitle ?? 'Virtual'} · ${v.fw}'
        : v.fw;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Micro(virtual ? 'Virtual firmware' : 'Firmware'),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: v == null ? '' : [if (virtual && ctl.virtual.libPath != null) ctl.virtual.libPath!, v.line, ...v.extra].join('\n'),
                child: Text(
                  text,
                  key: const Key('fw'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(TypeSize.body, color: v == null ? Pal.text3 : Pal.text1),
                ),
              ),
            ),
            if (v != null)
              IconBtn(
                Icons.copy,
                tooltip: 'Copy the version',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: [v.line, ...v.extra].join('\n')));
                  ctl.toast('Copied to the clipboard');
                },
              ),
          ],
        ),
      ],
    );
  }
}
