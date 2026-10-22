// Sound: every voice and effect parameter (undo/redo, reset, mutate, C export), My sounds, and
// the morph pad as a tool that opens on demand.

import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';
import 'side_panel.dart';
import 'sound_panel.dart';

class SoundTab extends StatelessWidget {
  final AppController ctl;
  const SoundTab(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PresetsPanel(ctl),
            const Divider(height: 1, thickness: 1, color: Pal.seam),
            MorphTool(ctl),
          ],
        );
        if (c.maxWidth >= Sizes.wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: SingleChildScrollView(child: SoundPanel(ctl))),
              const VerticalDivider(width: 1, thickness: 1, color: Pal.seam),
              SizedBox(width: Sizes.sideColumn, child: SingleChildScrollView(child: side)),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [SoundPanel(ctl), const Divider(height: 1, thickness: 1, color: Pal.seam), side],
          ),
        );
      },
    );
  }
}

/// The morph pad behind a header that opens and closes it (closed at first).
class MorphTool extends StatelessWidget {
  final AppController ctl;
  const MorphTool(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final open = ctl.morphOpen;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const Key('morph-toggle'),
                behavior: HitTestBehavior.opaque,
                onTap: () => ctl.setMorphOpen(!open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: open ? 0.25 : 0,
                        duration: Timing.fast,
                        child: const Icon(Icons.chevron_right, size: 18, color: Pal.muted),
                      ),
                      const SizedBox(width: Space.xs),
                      Text('Morph', style: ui(TypeSize.title, weight: FontWeight.w600)),
                      const SizedBox(width: Space.m),
                      Flexible(
                        child: Text(
                          'blend up to four captured sounds',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(TypeSize.small, color: Pal.faint),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: Timing.normal,
              curve: Timing.curve,
              alignment: Alignment.topCenter,
              child: open ? MorphPanel(ctl, showTitle: false) : const SizedBox(width: double.infinity),
            ),
          ],
        );
      },
    );
  }
}
