// Virtual's input in the header: "Input: LinnStrument" with a menu of the MIDI inputs the
// computer has (tick the ones that play the virtual Striso; the on-screen board always plays).
// The bytes go from the driver straight into the virtual firmware's own USB-MIDI input; this only
// chooses (MidiInputs).

import 'package:flutter/material.dart';
import 'package:striso_audio/striso_audio.dart';

import '../controller.dart';
import '../theme.dart';

class InputPicker extends StatelessWidget {
  final AppController ctl;
  final bool label;
  const InputPicker(this.ctl, {super.key, this.label = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.audioState, ctl.audioLevels]),
      builder: (context, _) {
        final m = ctl.midi;
        final devices = m?.devices ?? const <MidiInputStatus>[];
        final open = devices.where((d) => d.state == MidiInputState.open).toList();
        final text = open.isEmpty ? 'on-screen' : open.map((d) => d.name).join(', ');
        final activity = m?.activity ?? 0;
        final face = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Pip(activity > 0 ? Pal.ok : Pal.text3, size: 6, hollow: activity == 0),
            const SizedBox(width: Space.s),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: label ? 200 : 110),
              child: Text(
                label ? 'Input: $text' : text,
                key: const Key('input-picker'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(TypeSize.body, color: Pal.text2),
              ),
            ),
            const SizedBox(width: Space.xs),
            const Icon(Icons.expand_more, size: 14, color: Pal.text3),
          ],
        );
        if (m == null) {
          return Tooltip(message: 'MIDI input needs the audio engine (striso_audio); the on-screen board plays.', child: face);
        }
        return PopupMenuButton<String>(
          tooltip: 'What plays the virtual Striso: MIDI and MPE controllers on this computer (a Striso through its USB MIDI port too), and the on-screen board',
          color: Pal.bg1,
          position: PopupMenuPosition.under,
          onSelected: (id) {
            final s = m.status(id);
            m.select(id, !(s?.chosen ?? false));
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(enabled: false, height: Sizes.row, child: Text('MIDI INPUTS', style: microStyle())),
            if (devices.isEmpty)
              PopupMenuItem<String>(
                enabled: false,
                height: Sizes.row,
                child: Text('No MIDI inputs on this computer', style: ui(TypeSize.body, color: Pal.text3)),
              ),
            for (final d in devices)
              CheckedPopupMenuItem<String>(
                key: Key('midi-${d.id}'),
                value: d.id,
                checked: d.chosen,
                height: Sizes.row,
                child: Text(
                  '${d.name}${d.chosen && d.state != MidiInputState.open ? ' · ${d.text}' : ''}',
                  style: ui(TypeSize.body, color: d.present ? Pal.text1 : Pal.text3),
                ),
              ),
            PopupMenuItem<String>(
              enabled: false,
              height: Sizes.row,
              child: Text('The on-screen board always plays', style: ui(TypeSize.small, color: Pal.text3)),
            ),
          ],
          child: face,
        );
      },
    );
  }
}
