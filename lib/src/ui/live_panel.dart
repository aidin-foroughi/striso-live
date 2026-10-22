// The voices browser and the live area: board, motion, settings overlay panel, chord readout,
// progression, the probe line and the invite card.

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../harmony_tracker.dart';
import '../theme.dart';
import 'board_view.dart';

// ---------------------------------------------------------------------------------------------
// voices

class VoicesPanel extends StatelessWidget {
  final AppController ctl;
  final bool scroll;
  const VoicesPanel(this.ctl, {super.key, this.scroll = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final engines = <String, List<VoiceEntry>>{};
        for (final v in ctl.voices) {
          (engines[v.engine] ??= []).add(v);
        }
        final body = <Widget>[];
        if (ctl.voices.isEmpty) {
          body.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
              child: Text(
                ctl.connected
                    ? 'This firmware has no voice list (a single voice build).'
                    : 'Voices and presets appear here once the Striso is connected.',
                style: ui(13, color: Pal.faint),
              ),
            ),
          );
        }
        var k = 0;
        for (final MapEntry(key: engine, value: list) in engines.entries) {
          final info = engineInfo(engine, k++);
          body.add(
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: 8,
                      children: [
                        Text(info.label, style: ui(13.5, weight: FontWeight.w600)),
                        Text(info.blurb, style: ui(11.5, color: Pal.faint)),
                      ],
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, c) {
                      final cols = (c.maxWidth / 102).floor().clamp(1, 8);
                      final w = (c.maxWidth - 6 * (cols - 1)) / cols;
                      return Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final v in list)
                            SizedBox(
                              width: list.length == 1 ? c.maxWidth : w,
                              child: _Tile(
                                v: v,
                                info: info,
                                current: v.index == ctl.current,
                                pending: v.index == ctl.pendingVoice,
                                onTap: () => ctl.selectVoice(v.index),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        }
        final content = Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AreaHeadRow(
              'Voices',
              right: [
                Btn(
                  'Refresh',
                  kind: BtnKind.quiet,
                  small: true,
                  tooltip: 'Read the voice list again',
                  onPressed: ctl.connected ? ctl.syncVoice : null,
                ),
              ],
            ),
            if (scroll) Expanded(child: SingleChildScrollView(child: content)) else content,
          ],
        );
      },
    );
  }
}

class _Tile extends StatefulWidget {
  final VoiceEntry v;
  final EngineInfo info;
  final bool current, pending;
  final VoidCallback onTap;
  const _Tile({required this.v, required this.info, required this.current, required this.pending, required this.onTap});
  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final hue = widget.info.hue;
    final stripe = HSLColor.fromAHSL(1, hue, 0.45, 0.45).toColor();
    final hoverBorder = HSLColor.fromAHSL(1, hue, 0.60, 0.62).toColor();
    final cur = widget.current;
    return Tooltip(
      message: '${widget.v.name} (voice ${widget.v.index})',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Opacity(
            opacity: widget.pending ? 0.6 : 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: BoxDecoration(
                gradient: cur
                    ? const LinearGradient(colors: [Color(0x38F4D27A), Color(0x0FF4D27A)], begin: Alignment.topLeft, end: Alignment.bottomRight)
                    : null,
                color: cur ? null : Pal.panel2,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cur ? Pal.honey : (_hover ? hoverBorder : Pal.line)),
                boxShadow: cur ? const [BoxShadow(color: Color(0x2EF4D27A), blurRadius: 18)] : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned(left: 0, top: 0, bottom: 0, width: 3, child: ColoredBox(color: cur ? Pal.honey : stripe)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(9, 6, 8, 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.v.preset ?? widget.info.label,
                          style: ui(13.5, weight: FontWeight.w600, color: cur ? Pal.honey : Pal.text, height: 1.15),
                        ),
                        const SizedBox(height: 2),
                        Text('${widget.v.index}', style: ui(10.5, color: Pal.faint)),
                      ],
                    ),
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

// ---------------------------------------------------------------------------------------------
// live

class LivePanel extends StatelessWidget {
  final AppController ctl;
  final double boardHeight;
  const LivePanel(this.ctl, {super.key, this.boardHeight = 560});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LiveHead(ctl),
            SizedBox(
              height: boardHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: BoardView(ctl)),
                  SizedBox(
                    width: 150,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 4, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 4),
                            child: Text('Motion', style: ui(12.5, color: Pal.muted)),
                          ),
                          SizedBox(height: 200, child: MotionView(ctl)),
                          ListenableBuilder(
                            listenable: ctl.stats,
                            builder: (context, _) {
                              if (clockMs() - ctl.live.motion.t < 1500) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  ctl.mode == ConnMode.demo
                                      ? 'Simulated motion. In the demo you can also play the keys with the mouse.'
                                      : 'Motion data appears when the instrument sends it. If it stays empty, turn motion messages on in the Striso settings.',
                                  style: ui(11.5, color: Pal.faint, height: 1.35),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListenableBuilder(listenable: ctl, builder: (context, _) => ctl.settingsOn ? SettingsPanel(ctl) : const SizedBox.shrink()),
            HarmonyReadout(ctl),
            Progression(ctl),
            _Probe(ctl),
          ],
        ),
        Positioned.fill(top: 44, child: _Invite(ctl)),
      ],
    );
  }
}

class _LiveHead extends StatelessWidget {
  final AppController ctl;
  const _LiveHead(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => AreaHeadRow(
        'Live',
        left: [
          ListenableBuilder(
            listenable: ctl.stats,
            builder: (context, _) {
              final t = ctl.live.transpose;
              final stalled = ctl.streamStalled;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _stat('${ctl.live.activeCount()}', ' keys down'),
                  const SizedBox(width: 14),
                  Tooltip(
                    message: ctl.diagnosticsText().split('  |  ').join('\n'),
                    child: _stat(
                      '${ctl.live.rate.round()}',
                      stalled ? ' messages/s (stream silent)' : ' messages/s',
                      color: stalled ? Pal.honey : null,
                    ),
                  ),
                  if (t != 0) ...[
                    const SizedBox(width: 14),
                    Tooltip(
                      message: 'Transposition guessed from the octave buttons. Click to reset to D4 in the middle.',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: ctl.resetTranspose,
                          child: Text(
                            'Transposed ${t > 0 ? '+' : '−'}${t.abs() % 12 == 0 ? '${t.abs() ~/ 12} oct' : '${t.abs()} st'}',
                            style: ui(12.5, color: Pal.honey),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
        right: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SmallSelect<int>(
                width: 62,
                value: ctl.keyRoot,
                items: ctl.rootChoices,
                onChanged: ctl.keyScale == 'off' ? null : (v) => ctl.setKey(root: v),
              ),
              const SizedBox(width: 4),
              SmallSelect<String>(
                key: const Key('key-scale'),
                value: ctl.keyScale,
                items: [for (final id in scaleOrder) (id, scales[id]!.label)],
                onChanged: (v) => ctl.setKey(scale: v),
              ),
            ],
          ),
          Btn(
            'Settings keys',
            key: const Key('btn-settings-overlay'),
            small: true,
            pressed: ctl.settingsOn,
            tooltip: "Show what each key does in the Striso's settings mode (S)",
            onPressed: () => ctl.toggleSettings(),
          ),
          Seg<Names>(
            value: ctl.names,
            onChanged: ctl.setNames,
            items: const [
              (Names.octave, 'D4', 'Note names with octave'),
              (Names.letters, 'D', 'Note names'),
              (Names.degrees, '1 2 3', 'Scale degrees (pick a key)'),
              (Names.solfege, 'do re', 'Movable-do solfège (pick a key)'),
              (Names.off, 'None', 'No labels'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String b, String rest, {Color? color}) => Text.rich(
    TextSpan(
      style: ui(12.5, color: color ?? Pal.muted),
      children: [
        TextSpan(
          text: b,
          style: ui(12.5, color: color ?? Pal.text, weight: FontWeight.w600),
        ),
        TextSpan(text: rest),
      ],
    ),
  );
}

class _Invite extends StatelessWidget {
  final AppController ctl;
  const _Invite(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        if (ctl.connected) return const SizedBox.shrink();
        final busy = ctl.invite == InviteState.connecting;
        return Container(
          color: const Color(0x8015121F),
          alignment: Alignment.center,
          child: Container(
            key: const Key('invite'),
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 26),
            decoration: BoxDecoration(
              color: const Color(0xF01C1929),
              border: Border.all(color: Pal.line),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [BoxShadow(color: Color(0x8C05030C), blurRadius: 60, offset: Offset(0, 20))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Plug in your Striso', style: ui(26, weight: FontWeight.w300)),
                const SizedBox(height: 8),
                Text(
                  'Striso Live talks to the board directly over USB. Plug it in and switch it on.',
                  textAlign: TextAlign.center,
                  style: ui(14, color: Pal.muted),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Btn(
                      ctl.invite == InviteState.reconnect ? 'Connect now' : 'Connect',
                      key: const Key('btn-connect-2'),
                      kind: BtnKind.primary,
                      fontSize: 15,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      onPressed: busy ? null : ctl.userConnect,
                    ),
                    const SizedBox(width: 10),
                    Btn(
                      'Try the demo',
                      key: const Key('btn-demo'),
                      fontSize: 15,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      onPressed: busy ? null : ctl.connectDemo,
                    ),
                  ],
                ),
                if (ctl.inviteText.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy) ...[const StatusPulse(), const SizedBox(width: 8)],
                      Flexible(
                        child: Text(ctl.inviteText, style: ui(14, color: Pal.honey)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class StatusPulse extends StatefulWidget {
  const StatusPulse({super.key});
  @override
  State<StatusPulse> createState() => _StatusPulseState();
}

class _StatusPulseState extends State<StatusPulse> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 1, end: 0.3).animate(a),
    child: Container(
      width: 10,
      height: 10,
      decoration: const BoxDecoration(color: Pal.honey, shape: BoxShape.circle),
    ),
  );
}

class _Probe extends StatelessWidget {
  final AppController ctl;
  const _Probe(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.stats,
      builder: (context, _) {
        final id = ctl.hover, hc = ctl.hoverControl;
        final live = ctl.live;
        List<InlineSpan> spans = [];
        TextSpan b(String t) => TextSpan(
          text: t,
          style: ui(14, weight: FontWeight.w600),
        );
        TextSpan k(String t) => TextSpan(
          text: t,
          style: ui(12.5, color: Pal.faint),
        );
        TextSpan v(String t) => TextSpan(
          text: t,
          style: ui(12.5, color: Pal.muted),
        );
        const gap = TextSpan(text: '    ');
        if (ctl.settingsOn && (id >= 0 || hc >= 0)) {
          final f = id >= 0 ? settingsKeys[id] : null;
          final text = f != null
              ? f.describe(id)
              : id >= 0
              ? ['No settings function', 'key $id']
              : hc == 3
              ? ['Settings: hold it and press a key']
              : (settingsControls[hc] != null && hc != 3 ? [settingsControls[hc]!] : ['Glissando']);
          spans = [b(text.first), gap, v(text.skip(1).join('. '))];
        } else if (id >= 0) {
          final n = noteName(id, live.transpose, live.transposeFifths);
          spans = [
            b(n.full),
            gap,
            k('key '),
            v('$id'),
            gap,
            k('pressure '),
            v(live.raw[id].toStringAsFixed(3)),
            gap,
            k('velocity '),
            v(live.vpres[id].toStringAsFixed(2)),
            gap,
            k('tilt '),
            v('x ${live.x[id].toStringAsFixed(2)}  y ${live.y[id].toStringAsFixed(2)}'),
            if (ctl.playable) ...[gap, k('click and hold to play')],
          ];
        } else if (hc >= 0) {
          spans = [b(controls[hc].name), gap, v(live.controls[hc] == 1 ? 'pressed' : 'released')];
        }
        return Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Text.rich(TextSpan(children: spans)),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// settings overlay panel

class SettingsPanel extends StatelessWidget {
  final AppController ctl;
  const SettingsPanel(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final voices = ctl.settingsVoices();
    final groups = <String, List<MapEntry<int, SettingsKey>>>{};
    for (final e in settingsKeys.entries) {
      (groups[e.value.group] ??= []).add(e);
    }
    final how = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Settings mode on the Striso', style: ui(13.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final (i, t) in howToSettings.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${i + 1}. $t', style: ui(12.5, color: Pal.muted, height: 1.45)),
          ),
        const SizedBox(height: 4),
        Text(
          'From the firmware (synth_control.cpp config_but). Keys marked ? depend on the board’s stored settings. Click a voice key to switch voice; click it again for its next preset.',
          style: ui(12, color: Pal.faint, height: 1.4),
        ),
      ],
    );
    Widget group(String name, Color gc, List<Widget> items) => SizedBox(
      width: 270,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: ui(12, color: gc, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ...items,
        ],
      ),
    );
    final boxes = <Widget>[];
    for (final g in SettingsGroup.order) {
      final items = groups[g];
      if (items == null) continue;
      final gc = rgb(groupColors[g] ?? 0xffffff);
      boxes.add(
        group(g, gc, [
          for (final MapEntry(key: id, value: f) in items)
            _settingsItem(id, f, f.led != null ? rgb(ledColor(f.led!)) : (f.danger ? const Color(0xFFFF6B6B) : gc), voices[f.engine]),
        ]),
      );
    }
    boxes.add(
      group('Buttons with Settings held', Pal.honey, [
        for (final t in [settingsControls[1]!, settingsControls[2]!, settingsBothOctaves])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
            child: Text(t, style: ui(12.5)),
          ),
      ]),
    );
    return Container(
      key: const Key('settings-panel'),
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Pal.seam)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 900;
            final grid = Wrap(spacing: 18, runSpacing: 10, children: boxes);
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: c.maxWidth * 0.27, child: how),
                      const SizedBox(width: 18),
                      Expanded(child: grid),
                    ],
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [how, const SizedBox(height: 10), grid]);
          },
        ),
      ),
    );
  }

  Widget _settingsItem(int id, SettingsKey f, Color chipColor, SettingsVoice? v) {
    final parts = f.describe(id);
    final sel = id == ctl.settingsSelected;
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: sel ? Pal.panel2 : null,
        border: sel ? Border.all(color: Pal.glacier) : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 44),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: chipColor),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  f.short + (f.uncertain ? '?' : ''),
                  textAlign: TextAlign.center,
                  style: ui(11.5, color: chipColor, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: ui(12.5),
                    children: [
                      TextSpan(
                        text: parts.first,
                        style: ui(12.5, weight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: ' ${parts.skip(1).join('. ')}',
                        style: ui(12.5, color: Pal.faint),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (v != null)
            Padding(
              padding: const EdgeInsets.only(left: 52, top: 4),
              child: v.count == 0
                  ? Text('not in this firmware (the led shows red)', style: ui(12, color: Pal.faint))
                  : Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final p in v.list)
                          Btn(
                            p.preset ?? p.engine,
                            small: true,
                            pressed: p.index == ctl.current,
                            tooltip: 'Switch to ${p.name}',
                            onPressed: () => ctl.connected ? ctl.selectVoice(p.index) : ctl.toast('Connect to switch voices', 'warn'),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// chord, roman numeral, key and progression

class RomanText extends StatelessWidget {
  final Roman r;
  final double size;
  final Color color;
  const RomanText(this.r, {super.key, this.size = 44, this.color = Pal.honey});

  @override
  Widget build(BuildContext context) {
    final base = serif(size, color: color);
    Widget t(String s, double f, {bool top = false}) => Padding(
      padding: EdgeInsets.only(top: top ? size * 0.12 : 0),
      child: Text(s, style: serif(size * f, color: color)),
    );
    Widget figs(List<String> f) {
      if (f.isEmpty) return const SizedBox.shrink();
      final st = serif(size * 0.42, color: color).copyWith(height: 1);
      if (f.length == 1) {
        return Padding(
          padding: EdgeInsets.only(left: size * 0.06, bottom: size * 0.38),
          child: Text(f[0], style: st),
        );
      }
      return Padding(
        padding: EdgeInsets.only(left: size * 0.06),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f[0], style: st),
            Text(f[1], style: st),
          ],
        ),
      );
    }

    final children = <Widget>[];
    final special = r.special;
    if (special != null) {
      final m = RegExp(r'^(N|It|Fr|Ger)(\+?6)$').firstMatch(special);
      if (m != null) {
        children.addAll([
          Text(m[1]!, style: base),
          figs([m[2]!]),
        ]);
      } else {
        children.add(Text(special, style: base));
      }
    } else {
      final acc = r.acc > 0 ? '♯' * r.acc : (r.acc < 0 ? '♭' * -r.acc : '');
      children.add(Text('$acc${r.numeral}', style: base));
      if (r.mark.isNotEmpty) children.add(t(r.mark, 0.6, top: true));
      if (r.maj) children.add(t('maj', 0.6, top: true));
      children.add(figs(r.figs));
      if (r.suffix.isNotEmpty) children.add(t(r.suffix, 0.6, top: true));
      if (r.applied != null) {
        children.add(
          Padding(
            padding: EdgeInsets.only(left: size * 0.05),
            child: Text('/${r.applied}', style: serif(size * 0.8, color: color)),
          ),
        );
      }
    }
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: children);
  }
}

Color funcColor(String? f) => switch (f) {
  'T' => Pal.glacier,
  'S' => Pal.honey,
  'D' => Pal.ember,
  _ => Pal.line,
};

class HarmonyReadout extends StatelessWidget {
  final AppController ctl;
  const HarmonyReadout(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.harmony, ctl]),
      builder: (context, _) {
        final h = ctl.harmony;
        final a = h.shown;
        final key = ctl.currentKey;
        final dim = h.released ? 0.45 : 1.0;
        String sub;
        if (a == null) {
          sub = 'Hold two or more keys to name the chord.';
        } else if (a.kind == HarmonyKind.note) {
          sub = key != null ? 'scale degree ${a.degree} (${a.solfegeName})' : 'one note';
        } else if (a.kind == HarmonyKind.interval) {
          sub = '${a.long}  –  ${a.notes.join(' ')}';
        } else {
          sub = '${a.notes.join(' ')}  –  ${a.long}${a.alt != null ? '  –  ${a.alt}' : ''}';
        }
        final chord = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: dim,
              child: Tooltip(
                message: a?.alt != null ? 'also written ${a!.alt}' : '',
                child: Text(
                  a?.name ?? ' ',
                  key: const Key('h-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(46, weight: FontWeight.w600, height: 1.05),
                ),
              ),
            ),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(13, color: Pal.muted),
            ),
          ],
        );
        final romanBox = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 52,
              child: Opacity(
                opacity: dim,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: a?.roman != null
                      ? FittedBox(child: RomanText(a!.roman!))
                      : Text(a?.kind == HarmonyKind.note && key != null ? (a!.degree ?? '') : ' ', style: serif(44, color: Pal.honey)),
                ),
              ),
            ),
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  if (a?.roman != null) ...[
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: funcColor(a!.func), shape: BoxShape.circle),
                      child: Text(
                        a.func ?? '?',
                        style: ui(12.5, weight: FontWeight.w600, color: a.func == null ? Pal.muted : Pal.ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        a.funcLabel ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: ui(13, color: Pal.muted),
                      ),
                    ),
                    if (a.tag != null && a.tag != 'chromatic') ...[
                      const SizedBox(width: 8),
                      Text(a.tag == 'secondary' ? 'applied chord' : a.tag!, style: ui(13, color: Pal.faint)),
                    ],
                  ] else if (a?.kind == HarmonyKind.chord && key == null)
                    Flexible(
                      child: Text(
                        'Pick a key above for roman numerals and function.',
                        overflow: TextOverflow.ellipsis,
                        style: ui(13, color: Pal.muted),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
        final sug = h.suggestion;
        final keyBox = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(key?.name ?? 'No key', style: ui(15)),
            if (sug != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Sounds like ${sug.name} ', style: ui(12.5, color: Pal.muted)),
                    Btn('Use', small: true, onPressed: ctl.useSuggestedKey),
                  ],
                ),
              ),
          ],
        );
        return Container(
          constraints: const BoxConstraints(minHeight: 104),
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Pal.seam)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(flex: 125, child: chord),
              const SizedBox(width: 18),
              Expanded(flex: 100, child: romanBox),
              const SizedBox(width: 18),
              Expanded(
                flex: 90,
                child: Padding(padding: const EdgeInsets.only(bottom: 4), child: keyBox),
              ),
            ],
          ),
        );
      },
    );
  }
}

class Progression extends StatelessWidget {
  final AppController ctl;
  const Progression(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.harmony,
      builder: (context, _) {
        final prog = ctl.harmony.prog;
        return Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
          child: Row(
            children: [
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        if (prog.isEmpty) Text('Chords you play line up here.', style: ui(12.5, color: Pal.faint)),
                        for (final (i, e) in prog.indexed) Padding(padding: const EdgeInsets.only(right: 6), child: _chip(e, i == prog.length - 1)),
                      ],
                    ),
                  ),
                ),
              ),
              Btn('Clear', kind: BtnKind.quiet, small: true, onPressed: ctl.harmony.clearProgression),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(ProgEntry e, bool last) {
    final a = e.a;
    final fc = a.roman != null ? funcColor(a.func) : (last ? Pal.muted : Pal.line);
    return Tooltip(
      message: a.roman != null ? '${a.name}${a.funcLabel != null ? ' – ${a.funcLabel}' : ''}' : a.notes.join(' '),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 3, 10, 4),
        decoration: BoxDecoration(
          color: Pal.panel2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: last ? fc : Pal.line),
          // the function colour as an underline
          boxShadow: [BoxShadow(color: fc, offset: const Offset(0, 1.5))],
        ),
        child: a.roman != null ? Text(a.roman!.text, style: serif(16)) : Text(a.name, style: ui(13, color: Pal.muted)),
      ),
    );
  }
}
