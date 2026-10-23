// Through PC (DESIGN.md 4.5 components): the header's compact toggle with a level pip and the
// recording time, and the Audio section of Setup (devices, buffer and latency, gain, the input
// meter, the status line, Record and Show in folder). The audio itself runs natively
// (packages/striso_audio); these widgets show ThroughPc and call into it.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:striso_audio/striso_audio.dart';

import '../controller.dart';
import '../theme.dart';

/// Input peak (0..1) to 0..1 on a dB scale from -48 dBFS.
double levelPos(double peak) => peak <= 0 ? 0 : ((20 * math.log(peak) / math.ln10 + 48) / 48).clamp(0.0, 1.0);

/// m:ss (h:mm:ss from an hour).
String clockText(double seconds) {
  final s = seconds.floor();
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s % 3600 ~/ 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

Color toneColor(Tone t) => switch (t) {
  Tone.ok => Pal.ok,
  Tone.busy => Pal.accent,
  Tone.problem => Pal.error,
  Tone.quiet => Pal.text3,
};

/// Shows a file in Explorer / Finder.
Future<void> revealFile(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', path]);
    } else {
      await Process.start('xdg-open', [File(path).parent.path]);
    }
  } catch (_) {}
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;

// ---------------------------------------------------------------------------------------------
// header

/// The compact header control: a toggle ("Through PC" when there is room) and a 6 px level pip.
class ThroughToggle extends StatelessWidget {
  final AppController ctl;
  final bool label;
  const ThroughToggle(this.ctl, {super.key, this.label = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl.audioState,
      builder: (context, _) {
        final a = ctl.audio;
        final tip = [
          'Through PC: hear the Striso through this computer (its USB audio; the headphone jack keeps working).',
          if (a.state != ThroughState.off) a.message,
          ?a.outputNote,
          'Devices, buffer and gain: Setup › Audio',
        ].join('\n');
        final enabled = a.available;
        return Tooltip(
          message: enabled ? tip : a.message,
          child: Opacity(
            opacity: enabled ? 1 : 0.35,
            child: IgnorePointer(
              ignoring: !enabled,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Toggle(key: const Key('through-toggle'), value: a.through, onChanged: a.setThrough, label: label ? 'Through PC' : null),
                  const SizedBox(width: Space.s),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(onTap: () => ctl.setTab(AppTab.setup), child: LevelPip(ctl)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 6 px: hollow when off, the input level as brightness while running, accent while looking,
/// error when the input is gone or will not open.
class LevelPip extends StatelessWidget {
  final AppController ctl;
  const LevelPip(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.audioState, ctl.audioLevels]),
      builder: (context, _) {
        final a = ctl.audio;
        final s = a.state;
        if (s == ThroughState.off || s == ThroughState.unavailable || s == ThroughState.noUsbAudio) {
          return const Pip(Pal.text3, key: Key('through-pip'), size: 6, hollow: true);
        }
        if (s == ThroughState.running && a.outputNote == null) {
          final v = levelPos(a.level);
          return Pip(v > 0.995 ? Pal.error : Pal.t(0.2 + 0.8 * v), key: const Key('through-pip'), size: 6);
        }
        return Pip(toneColor(a.tone), key: const Key('through-pip'), size: 6);
      },
    );
  }
}

/// While recording: a red dot and the time; a click stops.
class RecIndicator extends StatelessWidget {
  final AppController ctl;
  const RecIndicator(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctl.audioState, ctl.audioLevels]),
      builder: (context, _) {
        final a = ctl.audio;
        if (!a.recording) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: Space.m),
          child: Tooltip(
            message: 'Recording the Striso to ${a.recordingPath}\nClick to stop',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const Key('rec-indicator'),
                onTap: a.stopRecording,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Pip(Pal.error, size: 8),
                    const SizedBox(width: Space.xs + 2),
                    Text(clockText(a.recordSeconds), style: ui(TypeSize.small)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Setup › Audio

class AudioSection extends StatefulWidget {
  final AppController ctl;
  const AudioSection(this.ctl, {super.key});
  @override
  State<AudioSection> createState() => _AudioSectionState();
}

class _AudioSectionState extends State<AudioSection> {
  ThroughPc get a => widget.ctl.audio;

  @override
  void initState() {
    super.initState();
    a.watchDevices(true); // the pickers stay fresh while this shows
  }

  @override
  void dispose() {
    a.watchDevices(false);
    super.dispose();
  }

  Widget _row(String label, Widget child, {String? tip}) {
    Widget w = SizedBox(
      height: Sizes.row + 4,
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: ui(TypeSize.body, color: Pal.text2)),
          ),
          Expanded(child: child),
        ],
      ),
    );
    if (tip != null) w = Tooltip(message: tip, waitDuration: const Duration(milliseconds: 700), child: w);
    return w;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctl.audioState,
      builder: (context, _) {
        final p = a.prefs;
        final enabled = a.available;
        final found = pickInput(a.inputs, null);
        final defOut = a.outputs.where((d) => d.isDefault).firstOrNull;
        // '' stands for automatic / the default (a null item value never reaches onSelected)
        final inputs = <(String, String)>[
          ('', found != null ? 'Automatic: ${found.name}' : 'Automatic (the Striso)'),
          for (final d in a.inputs) (d.name, d.name),
          if (p.input != null && !a.inputs.any((d) => d.name == p.input)) (p.input!, '${p.input} (not connected)'),
        ];
        final outputs = <(String, String)>[
          ('', defOut != null ? 'Default (${defOut.name})' : 'Default output'),
          for (final d in a.outputs) (d.name, d.name),
          if (p.output != null && !a.outputs.any((d) => d.name == p.output)) (p.output!, '${p.output} (not connected)'),
        ];
        final rec = a.recording;
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Micro('Audio'),
                const Spacer(),
                Toggle(key: const Key('audio-through'), value: p.through, onChanged: a.setThrough, label: 'Through PC'),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text('The Striso’s synth comes over USB; the headphone jack keeps working.', style: ui(TypeSize.small, color: Pal.text3)),
            const SizedBox(height: Space.s),
            _row(
              'Input',
              LayoutBuilder(
                builder: (context, box) => SmallSelect<String>(
                  key: const Key('audio-input'),
                  value: p.input ?? '',
                  items: inputs,
                  onChanged: rec ? null : (v) => a.setInput(v.isEmpty ? null : v),
                  width: box.maxWidth,
                ),
              ),
              tip: rec ? 'Stop the recording to change the input' : 'Automatic finds the Striso by its USB IDs or its name',
            ),
            _row(
              'Output',
              LayoutBuilder(
                builder: (context, box) => SmallSelect<String>(
                  key: const Key('audio-output'),
                  value: p.output ?? '',
                  items: outputs,
                  onChanged: (v) => a.setOutput(v.isEmpty ? null : v),
                  width: box.maxWidth,
                ),
              ),
            ),
            _row(
              'Buffer',
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Seg<int>(
                  value: p.period,
                  onChanged: rec ? (_) {} : a.setPeriod,
                  items: [
                    for (final f in AudioPrefs.periods)
                      (f, '$f', '$f frames per period (${(f / 48).toStringAsFixed(1)} ms): smaller is quicker, larger survives a busy computer'),
                  ],
                ),
              ),
              tip: rec ? 'Stop the recording to change the buffer' : null,
            ),
            _row('Latency', Align(alignment: Alignment.centerLeft, child: _Latency(widget.ctl))),
            if (Platform.isWindows)
              _row(
                '',
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Toggle(value: p.exclusive, onChanged: rec ? (_) {} : a.setExclusive, label: 'Exclusive input'),
                ),
                tip:
                    'On: the Striso’s input opens for Striso Live alone, with its own 24-bit samples and short periods (about 3 ms). '
                    'Off: shared with other programs, in 10 ms periods. Falls back to shared when another program holds it.',
              ),
            if (Platform.isWindows)
              _row(
                '',
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Toggle(value: p.exclusiveOutput, onChanged: a.setExclusiveOutput, label: 'Exclusive output'),
                ),
                tip:
                    'On: the output plays only the Striso, for the lowest latency (many outputs allow no less than 10 ms when shared). '
                    'Other programs cannot play to it meanwhile. Falls back to shared when it cannot.',
              ),
            _row('Gain', _Gain(a)),
            _row('Level', _LevelBars(widget.ctl)),
            const SizedBox(height: Space.xs),
            _StatusLine(widget.ctl),
            const SizedBox(height: Space.m),
            _RecordRow(widget.ctl),
          ],
        );
        return Opacity(
          opacity: enabled ? 1 : 0.5,
          child: IgnorePointer(ignoring: !enabled, child: body),
        );
      },
    );
  }
}

class _Latency extends StatelessWidget {
  final AppController ctl;
  const _Latency(this.ctl);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctl.audioLevels,
    builder: (context, _) {
      final a = ctl.audio;
      final st = a.st;
      final on = a.playing && st.latencyMs > 0;
      return Tooltip(
        message: on
            ? 'Through the computer: input period ${(st.capturePeriod / (st.captureRate > 0 ? st.captureRate : 48000) * 1000).toStringAsFixed(1)} ms'
                  ' + ring ${st.ringMs.toStringAsFixed(1)} ms (aims at ${st.targetMs.toStringAsFixed(1)})'
                  ' + output buffer. The board adds about 3 ms before USB, the output device its own.\n'
                  'Clock drift corrected: ${st.driftPpm.toStringAsFixed(0)} ppm'
            : 'The latency shows while Through PC plays',
        child: Text(on ? '${st.latencyMs.toStringAsFixed(1)} ms' : '–', key: const Key('audio-latency'), style: ui(TypeSize.body)),
      );
    },
  );
}

class _Gain extends StatefulWidget {
  final ThroughPc a;
  const _Gain(this.a);
  @override
  State<_Gain> createState() => _GainState();
}

class _GainState extends State<_Gain> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final db = _drag ?? widget.a.prefs.gainDb;
    final text = db <= AudioPrefs.minDb ? 'off' : '${db > 0 ? '+' : (db < 0 ? '−' : '')}${db.abs().toStringAsFixed(1)} dB';
    return Row(
      children: [
        Expanded(
          child: Slider(
            key: const Key('audio-gain'),
            value: db,
            min: AudioPrefs.minDb,
            max: AudioPrefs.maxDb,
            onChanged: (v) => setState(() => _drag = (v * 2).round() / 2),
            onChangeEnd: (v) {
              widget.a.setGainDb((v * 2).round() / 2);
              setState(() => _drag = null);
            },
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(text, textAlign: TextAlign.right, style: ui(TypeSize.body)),
        ),
        SizedBox(
          width: Sizes.control,
          child: db != -6 ? IconBtn(Icons.replay, tooltip: 'Back to −6 dB', onPressed: () => widget.a.setGainDb(-6)) : null,
        ),
      ],
    );
  }
}

/// The input, left and right: 4 px bars (bg3 track, accent; error at full scale).
class _LevelBars extends StatelessWidget {
  final AppController ctl;
  const _LevelBars(this.ctl);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctl.audioLevels,
    builder: (context, _) {
      final st = ctl.audio.st;
      return Semantics(
        label: 'Input level',
        child: SizedBox(
          height: 14,
          child: CustomPaint(painter: _BarsPainter(levelPos(st.levelL), levelPos(st.levelR), st.levelL >= 0.999 || st.levelR >= 0.999)),
        ),
      );
    },
  );
}

class _BarsPainter extends CustomPainter {
  final double l, r;
  final bool clip;
  _BarsPainter(this.l, this.r, this.clip);
  @override
  void paint(Canvas g, Size s) {
    const h = 4.0;
    for (final (i, v) in [l, r].indexed) {
      final y = i == 0 ? 2.0 : s.height - 2 - h;
      g.drawRRect(RRect.fromLTRBR(0, y, s.width - 28, y + h, const Radius.circular(2)), Paint()..color = Pal.bg3);
      if (v > 0) g.drawRRect(RRect.fromLTRBR(0, y, (s.width - 28) * v, y + h, const Radius.circular(2)), Paint()..color = clip ? Pal.error : Pal.accent);
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter o) => o.l != l || o.r != r || o.clip != clip;
}

class _StatusLine extends StatelessWidget {
  final AppController ctl;
  const _StatusLine(this.ctl);
  @override
  Widget build(BuildContext context) {
    final a = ctl.audio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 5), child: Pip(toneColor(a.tone))),
            const SizedBox(width: Space.s),
            Expanded(
              child: Text(a.message, key: const Key('audio-status'), style: ui(TypeSize.small, color: a.tone == Tone.problem ? Pal.text1 : Pal.text2)),
            ),
          ],
        ),
        ListenableBuilder(
          listenable: ctl.audioLevels,
          builder: (context, _) {
            final live = a.liveLine;
            if (live.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(live, style: ui(TypeSize.small, color: a.st.dropouts > 0 ? Pal.accent : Pal.text3)),
            );
          },
        ),
        if (a.outputNote != null)
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Text(a.outputNote!, style: ui(TypeSize.small, color: Pal.error)),
          ),
        if (a.state == ThroughState.denied && Platform.isMacOS)
          Padding(
            padding: const EdgeInsets.only(left: 6, top: Space.xs),
            child: Btn(
              'Open Privacy settings',
              kind: BtnKind.ghost,
              onPressed: () => Process.start('open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone']),
            ),
          ),
      ],
    );
  }
}

class _RecordRow extends StatelessWidget {
  final AppController ctl;
  const _RecordRow(this.ctl);
  @override
  Widget build(BuildContext context) {
    final a = ctl.audio;
    final rec = a.recording;
    final last = a.lastRecording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Btn(
              rec ? 'Stop' : 'Record',
              key: const Key('audio-record'),
              icon: rec ? Icons.stop : Icons.fiber_manual_record,
              kind: rec ? BtnKind.danger : BtnKind.secondary,
              tooltip: rec
                  ? 'Stop and finish the file'
                  : 'Records the Striso’s input to a WAV file (48 kHz stereo, 24 bit when the Striso sends 24) in Documents › Striso Live Recordings',
              onPressed: rec ? a.stopRecording : a.startRecording,
            ),
            const SizedBox(width: Space.m),
            if (rec)
              ListenableBuilder(
                listenable: ctl.audioLevels,
                builder: (context, _) => Text(
                  '${clockText(a.recordSeconds)}${ThroughPc.bitsText(a.st.recordBits).isNotEmpty ? ' · ${ThroughPc.bitsText(a.st.recordBits)}' : ''}',
                  key: const Key('audio-rec-time'),
                  style: ui(TypeSize.body),
                ),
              ),
          ],
        ),
        if (!rec && last != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: last,
                    child: Text(_base(last), maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.small, color: Pal.text2)),
                  ),
                ),
                Btn('Show in folder', key: const Key('audio-reveal'), kind: BtnKind.ghost, onPressed: () => revealFile(last)),
              ],
            ),
          ),
        if (a.recordNote != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(a.recordNote!, style: ui(TypeSize.small, color: Pal.error)),
          ),
      ],
    );
  }
}
