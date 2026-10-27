// Around the board: the harmony strip (DESIGN.md 4.4: chord, roman numeral and function, the
// progression, the key), the hover readout, and the settings-keys detail for the Setup tab.

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../harmony_tracker.dart';
import '../theme.dart';
import 'voice_keys.dart';

class RomanText extends StatelessWidget {
  final Roman r;
  final double size;
  final Color color;
  const RomanText(this.r, {super.key, this.size = TypeSize.roman, this.color = Pal.accent});

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

const _functionWord = {'T': 'tonic', 'S': 'subdominant', 'D': 'dominant'};

String chordSub(Harmony? a, MusicKey? key) {
  if (a == null) return 'Hold two or more keys to name the chord.';
  if (a.kind == HarmonyKind.note) return key != null ? 'scale degree ${a.degree} (${a.solfegeName})' : 'one note';
  if (a.kind == HarmonyKind.interval) return a.long;
  return '${a.long}${a.alt != null ? ' · also ${a.alt}' : ''}';
}

/// The harmony strip: 96 px, chord | roman, function and progression | key.
class HarmonyStrip extends StatelessWidget {
  final AppController ctl;
  final bool compact;
  const HarmonyStrip(this.ctl, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.harmony, ctl]),
      builder: (context, _) {
        final h = ctl.harmony;
        final a = h.shown;
        final key = ctl.currentKey;
        final dim = h.released ? 0.42 : 1.0;
        final chord = SizedBox(
          width: compact ? 200 : 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: Timing.quick,
                child: Opacity(
                  key: ValueKey(a?.name),
                  opacity: dim,
                  child: Tooltip(
                    message: a?.alt != null ? 'also written ${a!.alt}' : '',
                    child: Text(
                      a?.name ?? ' ',
                      key: const Key('h-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(TypeSize.chord, weight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
              Text(
                chordSub(a, key),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(TypeSize.small, color: Pal.text2),
              ),
            ],
          ),
        );
        final roman = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (a?.roman != null) ...[
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Opacity(opacity: dim, child: RomanText(a!.roman!)),
                ),
              ),
              const SizedBox(width: Space.s),
              Flexible(
                child: Text(
                  a.funcLabel?.toLowerCase() ?? _functionWord[a.func] ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(TypeSize.small, color: Pal.text2),
                ),
              ),
              const SizedBox(width: Space.l),
            ] else if (a?.kind == HarmonyKind.note && key != null) ...[
              Opacity(
                opacity: dim,
                child: Text(a!.degree ?? '', style: serif(TypeSize.roman, color: Pal.accent)),
              ),
              const SizedBox(width: Space.l),
            ] else if (a?.kind == HarmonyKind.chord && key == null) ...[
              Flexible(
                child: Text(
                  'Pick a key for roman numerals',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(TypeSize.small, color: Pal.text3),
                ),
              ),
              const SizedBox(width: Space.l),
            ],
            Expanded(child: Progression(ctl)),
          ],
        );
        final sug = h.suggestion;
        final bh = barryHarrisText(key);
        final keyBox = SizedBox(
          width: compact ? 220 : 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(key?.name ?? 'No key', style: ui(TypeSize.body, color: key == null ? Pal.text3 : Pal.text1)),
              if (ctl.nonTwelve)
                Tooltip(
                  message: 'Chords, scales and roman numerals are named by the keys’ spelling, as in 12-TET; the board plays ${ctl.tuningName}.',
                  child: Text(
                    'chords by spelling · board in ${ctl.tuningName}',
                    key: const Key('tuning-note'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(TypeSize.small, color: Pal.text3),
                  ),
                ),
              if (bh != null)
                Tooltip(
                  message:
                      'Barry Harris: alternate scale tones belong to the chord and to the diminished seventh chord.\n'
                      'On the board the chord tones have solid rims, the diminished tones dashed rims.',
                  child: Text(
                    bh,
                    key: const Key('bh-text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(TypeSize.small, color: Pal.text2),
                  ),
                ),
              if (sug != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        'Sounds like ${sug.name}',
                        overflow: TextOverflow.ellipsis,
                        style: ui(TypeSize.small, color: Pal.text2),
                      ),
                    ),
                    const SizedBox(width: Space.xs),
                    _LinkButton('Use', onTap: ctl.useSuggestedKey),
                  ],
                ),
            ],
          ),
        );
        return SizedBox(
          height: Sizes.harmony,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              children: [
                chord,
                const SizedBox(width: Space.column),
                Expanded(child: roman),
                const SizedBox(width: Space.column),
                keyBox,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LinkButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _LinkButton(this.label, {required this.onTap});
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: ui(TypeSize.small, color: Pal.accent, weight: FontWeight.w500),
      ),
    ),
  );
}

/// The progression as ghost chips, newest right; Clear at the end.
class Progression extends StatelessWidget {
  final AppController ctl;
  const Progression(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.harmony,
      builder: (context, _) {
        final h = ctl.harmony;
        // the chord still held is the big numeral: its chip joins the row once it is released
        final shown = h.shown;
        final held = !h.released && shown != null && h.prog.isNotEmpty && h.prog.last.a.name == shown.name;
        final prog = held ? h.prog.sublist(0, h.prog.length - 1) : h.prog;
        return Row(
          children: [
            Expanded(
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      if (h.prog.isEmpty) Text('Chords you play line up here.', style: ui(TypeSize.small, color: Pal.text3)),
                      for (final e in prog) _Chip(e),
                    ],
                  ),
                ),
              ),
            ),
            if (h.prog.isNotEmpty) Btn('Clear', kind: BtnKind.ghost, onPressed: ctl.harmony.clearProgression),
          ],
        );
      },
    );
  }
}

class _Chip extends StatefulWidget {
  final ProgEntry e;
  const _Chip(this.e);
  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final a = widget.e.a;
    return Tooltip(
      message: a.roman != null ? '${a.name}${a.funcLabel != null ? ' – ${a.funcLabel}' : ''}' : a.notes.join(' '),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          height: 24,
          margin: const EdgeInsets.only(right: Space.xs),
          padding: const EdgeInsets.symmetric(horizontal: Space.s),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.small),
            border: Border.all(color: _hover ? Pal.hairline : Colors.transparent),
          ),
          child: a.roman != null ? Text(a.roman!.text, style: serif(15, color: Pal.text2)) : Text(a.name, style: ui(TypeSize.body, color: Pal.text2)),
        ),
      ),
    );
  }
}

/// The key under the pointer: note, key number, pressure, velocity, tilt (or its settings-mode
/// function in the Setup tab's settings mode).
class HoverReadout extends StatelessWidget {
  final AppController ctl;
  const HoverReadout(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.stats,
      builder: (context, _) {
        final id = ctl.hover, hc = ctl.hoverControl;
        final live = ctl.live;
        String text = '';
        if (ctl.settingsOn && ctl.tab == AppTab.setup && (id >= 0 || hc >= 0)) {
          final f = id >= 0 ? ctl.settingsLayout[id] : null;
          text = ctl.settingsLayout.isEmpty
              ? 'Connect to see what each key does in settings mode (the Striso lists it) · key $id'
              : f != null
              ? [
                  ...f.describe(id),
                  if ((f.engine != null || f.switchable) && !ctl.canSend)
                    ctl.sendHint
                  else if (f.engine != null)
                    'click to select${ctl.caps?.tag != null ? ' (on ${ctl.caps!.name})' : ''}'
                  else if (f.switchable)
                    'click to switch${ctl.caps?.tag != null ? ' (on ${ctl.caps!.name})' : ''}'
                  else if (f.group == SettingsGroup.sens)
                    'set it under Sensitivity'
                  else if (!f.danger && f.knob != null)
                    'a dial: set on the instrument',
                ].join(' · ')
              : id >= 0
              ? 'No settings function · key $id'
              : hc == 3
              ? 'Settings: hold it and press a key'
              : (settingsControls[hc] ?? 'Glissando');
        } else if (id >= 0) {
          final n = ctl.keyLayout!.noteName(id, live.transpose, live.transposeFifths);
          final f = ctl.tab == AppTab.setup ? ctl.keyParam(id)?.value : null;
          final pitchy = ctl.names == Names.pitch || ctl.names == Names.cents || ctl.nonTwelve;
          final q = pitchy ? ctl.qtLabel(id) : null;
          text = [
            n.full,
            if (q != null) ...[
              '${centsText(q.centsFrom12, decimals: 1)} ¢ vs 12-TET',
              if (q.nearest != 0 || q.frac.abs() >= qtDrawThreshold)
                'nearest quarter tone ${q.letter} ${q.accidentalName}${q.frac.abs() >= qtDrawThreshold ? ' ${centsText(q.fracCents)} ¢' : ''}',
              if (q.respelled) 'respelled',
            ],
            'key $id',
            'pressure ${live.raw[id].toStringAsFixed(3)}',
            'velocity ${live.vpres[id].toStringAsFixed(2)}',
            'tilt ${live.x[id].toStringAsFixed(2)} ${live.y[id].toStringAsFixed(2)}',
            if (f != null) '×${f.toStringAsFixed(2)}',
          ].join(' · ');
        } else if (hc >= 0) {
          text = '${controls[hc].name} · ${live.controls[hc] == 1 ? 'pressed' : 'released'}';
        }
        return Text(
          text,
          key: const Key('hover-readout'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ui(TypeSize.small, color: Pal.text2),
        );
      },
    );
  }
}

/// Setup, settings keys mode: the how-to (two lines and More), the selected or hovered key's
/// function, and for voice keys the engine's presets.
class SettingsInfo extends StatefulWidget {
  final AppController ctl;
  const SettingsInfo(this.ctl, {super.key});
  @override
  State<SettingsInfo> createState() => _SettingsInfoState();
}

class _SettingsInfoState extends State<SettingsInfo> {
  bool more = false;

  @override
  Widget build(BuildContext context) {
    final ctl = widget.ctl;
    return ListenableBuilder(
      listenable: Listenable.merge([ctl, ctl.stats]),
      builder: (context, _) {
        final id = ctl.hover >= 0 ? ctl.hover : ctl.settingsSelected;
        final f = id >= 0 ? ctl.settingsLayout[id] : null;
        final voices = ctl.settingsVoices();
        final v = f?.engine != null ? voices[f!.engine] : null;
        // a voice key: the board's voice-key map (Stca) says what is on it, loaded or not
        final slot = id >= 0 ? ctl.voiceKeys[id] : null;
        return Column(
          key: const Key('settings-panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Micro('Settings mode'),
            const SizedBox(height: Space.s),
            Text(howToSettings[0], style: ui(TypeSize.body, color: Pal.text2)),
            const SizedBox(height: Space.xs),
            Text(howToSettings[1], style: ui(TypeSize.body, color: Pal.text2)),
            Align(
              alignment: Alignment.centerLeft,
              child: Btn(more ? 'Less' : 'More ▸', kind: BtnKind.ghost, onPressed: () => setState(() => more = !more)),
            ),
            if (more) ...[
              for (final t in howToSettings.skip(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: Text(t, style: ui(TypeSize.body, color: Pal.text2)),
                ),
              Text(
                'From the firmware (synth_control.cpp config_but). Keys marked ? depend on the board’s stored settings. '
                'Click a voice key to switch voice; click it again for its next preset.',
                style: ui(TypeSize.small, color: Pal.text3),
              ),
              const SizedBox(height: Space.s),
              for (final t in [settingsControls[1]!, settingsControls[2]!, settingsBothOctaves])
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: Text(t, style: ui(TypeSize.small, color: Pal.text2)),
                ),
            ],
            const SizedBox(height: Space.l),
            if (slot != null)
              VoiceKeyEditor(ctl, slot, editable: id == ctl.settingsSelected)
            else if (f == null)
              Text(id >= 0 ? 'Key $id has no settings function.' : 'Point at a key, or click one.', style: ui(TypeSize.body, color: Pal.text2))
            else ...[
              Text(
                '${f.title}${f.uncertain ? ' (?)' : ''}',
                style: ui(TypeSize.title, weight: FontWeight.w600, color: f.danger ? Pal.error : Pal.text1),
              ),
              const SizedBox(height: Space.xs),
              for (final line in f.describe(id).skip(1)) Text(line, style: ui(TypeSize.body, color: Pal.text2)),
              if ((f.engine != null || f.switchable) && !ctl.canSend)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    ctl.sendHint,
                    key: const Key('settings-send-hint'),
                    style: ui(TypeSize.body, color: Pal.text3),
                  ),
                )
              else if ((f.engine != null || f.switchable) && ctl.caps?.tag != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    'Acts on ${ctl.caps!.name}.',
                    style: ui(TypeSize.small, color: Pal.demo),
                  ),
                ),
              if (v != null) ...[
                const SizedBox(height: Space.m),
                if (v.count == 0) Text('Not in this firmware.', style: ui(TypeSize.body, color: Pal.text3)),
                for (final p in v.list)
                  _PresetLine(
                    label: p.preset ?? p.engine,
                    current: p.index == ctl.current,
                    color: engineColor(p.engine),
                    onTap: () => ctl.canSend ? ctl.selectVoice(p.index) : ctl.toast(ctl.sendHint, 'warn'),
                  ),
              ],
            ],
          ],
        );
      },
    );
  }
}

class _PresetLine extends StatefulWidget {
  final String label;
  final bool current;
  final Color color;
  final VoidCallback onTap;
  const _PresetLine({required this.label, required this.current, required this.color, required this.onTap});
  @override
  State<_PresetLine> createState() => _PresetLineState();
}

class _PresetLineState extends State<_PresetLine> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: Sizes.row,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        decoration: BoxDecoration(color: _hover ? Pal.bg2 : null, borderRadius: BorderRadius.circular(Radii.small)),
        child: Row(
          children: [
            SizedBox(width: 12, child: widget.current ? Pip(widget.color) : null),
            Text(
              widget.label,
              style: ui(TypeSize.body, color: widget.current ? Pal.text1 : Pal.text2, weight: widget.current ? FontWeight.w500 : FontWeight.w400),
            ),
          ],
        ),
      ),
    ),
  );
}
