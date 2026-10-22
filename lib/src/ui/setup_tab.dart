// Setup: touch sensitivity and the key equalizer with the big board, the settings-keys overlay,
// Save to Striso, the motion sensor and the firmware version.

import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';
import 'board_view.dart';
import 'live_panel.dart';
import 'touch_panel.dart';

class SetupTab extends StatelessWidget {
  final AppController ctl;
  const SetupTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(child: TouchGlobal(ctl)),
        const Divider(height: 1, thickness: 1, color: Pal.seam),
        _Section(child: KeyEqualizer(ctl)),
        const Divider(height: 1, thickness: 1, color: Pal.seam),
        _Section(child: SaveBox(ctl)),
      ],
    );
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(child: _Motion(ctl)),
        const Divider(height: 1, thickness: 1, color: Pal.seam),
        _Section(child: _Firmware(ctl)),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= Sizes.wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: Sizes.sideColumn + 60, child: SingleChildScrollView(child: left)),
              const VerticalDivider(width: 1, thickness: 1, color: Pal.seam),
              Expanded(child: _SetupBoard(ctl)),
              const VerticalDivider(width: 1, thickness: 1, color: Pal.seam),
              SizedBox(width: Sizes.rightColumn - 60, child: SingleChildScrollView(child: right)),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: (c.maxWidth / 1.15).clamp(360.0, 640.0) + 120, child: _SetupBoard(ctl)),
              const Divider(height: 1, thickness: 1, color: Pal.seam),
              left,
              const Divider(height: 1, thickness: 1, color: Pal.seam),
              right,
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  final Widget child;
  const _Section({required this.child});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.l), child: child);
}

/// The board with the key equalizer or the settings-keys overlay, and the settings-mode panel.
class _SetupBoard extends StatelessWidget {
  final AppController ctl;
  const _SetupBoard(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.xs),
            child: Wrap(
              spacing: Space.l,
              runSpacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  ctl.settingsOn ? 'What each key does with Settings held' : 'Key sensitivity on the board',
                  style: ui(TypeSize.title, weight: FontWeight.w600),
                ),
                Btn(
                  'Settings keys',
                  key: const Key('btn-settings-overlay'),
                  small: true,
                  pressed: ctl.settingsOn,
                  tooltip: "Show what each key does in the Striso's settings mode (S)",
                  onPressed: () => ctl.toggleSettings(),
                ),
                if (!ctl.settingsOn) CheckLabel('Show key factors and peaks', key: const Key('eq-on'), value: ctl.eqOn, onChanged: ctl.setEqOn),
              ],
            ),
          ),
          Expanded(child: BoardView(ctl, overlays: true)),
          ProbeLine(ctl),
          if (ctl.settingsOn) SettingsPanel(ctl),
        ],
      ),
    );
  }
}

class _Motion extends StatelessWidget {
  final AppController ctl;
  const _Motion(this.ctl);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Motion', style: ui(TypeSize.title, weight: FontWeight.w600)),
        const SizedBox(height: Space.s),
        SizedBox(height: 200, child: MotionView(ctl)),
        ListenableBuilder(
          listenable: ctl.stats,
          builder: (context, _) {
            if (clockMs() - ctl.live.motion.t < 1500) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(
                ctl.mode == ConnMode.demo
                    ? 'Simulated motion. In the demo you can also play the keys with the mouse.'
                    : 'Motion data appears when the instrument sends it. If it stays empty, turn motion messages on in the Striso settings.',
                style: ui(TypeSize.caption, color: Pal.faint, height: 1.35),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Firmware extends StatelessWidget {
  final AppController ctl;
  const _Firmware(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final v = ctl.version;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Firmware', style: ui(TypeSize.title, weight: FontWeight.w600)),
            const SizedBox(height: Space.s),
            if (v == null)
              Text(ctl.connected ? 'The board did not report its version.' : 'Connect to read the firmware version.', style: ui(TypeSize.label, color: Pal.faint))
            else ...[
              SelectableText(v.fw, key: const Key('fw'), style: ui(TypeSize.body)),
              const SizedBox(height: Space.xs),
              SelectableText([v.line, ...v.extra].join('\n'), style: mono(TypeSize.caption, color: Pal.faint)),
            ],
            const SizedBox(height: Space.m),
            Text('${ctl.voices.length} voices', style: ui(TypeSize.small, color: Pal.muted)),
          ],
        );
      },
    );
  }
}
