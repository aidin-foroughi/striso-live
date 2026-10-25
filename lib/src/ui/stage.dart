// Stage mode (DESIGN.md 6.1, F or F11; Esc leaves): the board fills the window, the header
// shrinks to a 24 px strip (dot, sound name, CPU), the chord sits over the bottom 80 px in the
// stage type, labels are 1.3 times larger. Readable from two metres.

import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'header.dart';
import 'live_panel.dart';
import 'play_tab.dart';

class StageView extends StatelessWidget {
  final AppController ctl;
  const StageView(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('stage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: ctl,
          builder: (context, _) => Container(
            height: Sizes.stageStrip,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              children: [
                StatusDot(ctl.dot, lost: ctl.lost || ctl.problem != null),
                const SizedBox(width: Space.s),
                Text(ctl.voiceName.isEmpty ? 'Nothing playing' : (ctl.lastSound ?? ctl.nowPreset), style: ui(TypeSize.body, weight: FontWeight.w500)),
                const Spacer(),
                if (ctl.connected) CpuIndicator(ctl),
                const SizedBox(width: Space.m),
                IconBtn(Icons.fullscreen_exit, tooltip: 'Leave stage mode (Esc)', onPressed: () => ctl.setStage(false)),
              ],
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(bottom: 40, child: BoardStage(ctl, labelScale: 1.3)),
              Positioned(left: 0, right: 0, bottom: 0, height: 80, child: _StageChord(ctl)),
            ],
          ),
        ),
      ],
    );
  }
}

class _StageChord extends StatelessWidget {
  final AppController ctl;
  const _StageChord(this.ctl);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.harmony, ctl]),
      builder: (context, _) {
        final a = ctl.harmony.shown;
        return Container(
          color: Pal.bg0.withValues(alpha: 0.6),
          padding: const EdgeInsets.symmetric(horizontal: Space.xl),
          child: Row(
            children: [
              Opacity(
                opacity: ctl.harmony.released ? 0.42 : 1,
                child: Text(
                  a?.name ?? '',
                  key: const Key('stage-chord'),
                  style: ui(TypeSize.stage, weight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: Space.xl),
              if (a?.roman != null) RomanText(a!.roman!, size: 40),
              const Spacer(),
              Text(ctl.currentKey?.name ?? '', style: ui(TypeSize.sound, color: Pal.text2)),
            ],
          ),
        );
      },
    );
  }
}
