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

  /// A row whose value has a second line under it (micro type): the label stays on the first.
  Widget _rowTall(String label, Widget child) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xs + 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(label, style: ui(TypeSize.body, color: Pal.text2)),
        ),
        Expanded(child: child),
      ],
    ),
  );

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
        // Virtual: the output alone (its source is the virtual Striso); Through PC is the Striso's
        final virtual = widget.ctl.isVirtual;
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Micro('Audio'),
                const Spacer(),
                if (!virtual) Toggle(key: const Key('audio-through'), value: p.through, onChanged: a.setThrough, label: 'Through PC'),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              virtual
                  ? 'The virtual Striso plays to this output.'
                  : 'Through PC: the Striso’s synth comes over USB to this computer while it is connected; the headphone jack keeps working.',
              style: ui(TypeSize.small, color: Pal.text3),
            ),
            const SizedBox(height: Space.s),
            if (!virtual) _row(
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
            if (a.outputHint != null) _Hint(a.outputHint!, warn: a.outputBluetooth),
            _row(
              'Buffer',
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Seg<int>(
                  value: p.period,
                  onChanged: rec ? (_) {} : a.setPeriod,
                  keys: {for (final f in [AudioPrefs.auto, ...AudioPrefs.periods]) f: Key('audio-buffer-$f')},
                  items: [
                    (
                      AudioPrefs.auto,
                      'Auto',
                      'Recommended. Starts safe, gets quicker while it plays without a dropout, steps back at the first one, '
                          'and remembers the best for each output',
                    ),
                    for (final f in AudioPrefs.periods)
                      (f, '$f', '$f frames per period (${(f / 48).toStringAsFixed(1)} ms): smaller is quicker, larger survives a busy computer'),
                  ],
                ),
              ),
              tip: rec ? 'Stop the recording to change the buffer' : null,
            ),
            _AutoLine(widget.ctl),
            _rowTall('Latency', _Latency(widget.ctl)),
            _row(
              'Granted',
              ListenableBuilder(
                listenable: widget.ctl.audioLevels,
                builder: (context, _) {
                  final g = widget.ctl.audio.grantedLine;
                  return Text(g.isEmpty ? '–' : g, key: const Key('audio-granted'), style: ui(TypeSize.small, color: Pal.text2), overflow: TextOverflow.ellipsis);
                },
              ),
              tip: 'What the system granted for the input and the output, whatever the toggles ask',
            ),
            _rowTall('Dropouts', _Dropouts(widget.ctl)),
            if (a.boardTargetSupported == true && !virtual) ...[
              _row(
                'Striso buffer',
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Seg<int>(
                    value: p.boardBuffer,
                    onChanged: a.setBoardBuffer,
                    keys: {for (final f in [AudioPrefs.auto, ...AudioPrefs.boardBuffers]) f: Key('audio-board-$f')},
                    items: [
                      (AudioPrefs.auto, 'Auto', 'The smallest that keeps the Striso at no underruns (its own counters, every 2 s)'),
                      for (final f in AudioPrefs.boardBuffers)
                        (f, '$f', '$f frames (${(f / 48).toStringAsFixed(2)} ms) in the Striso before each USB packet: smaller is quicker'),
                    ],
                  ),
                ),
                tip: 'The Striso’s own buffer before USB. Set from the app on every connection (the Striso does not keep it).',
              ),
              _BoardLine(widget.ctl),
            ],
            if (Platform.isWindows && !virtual)
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
                    'On: a wired output plays only the Striso, for the lowest latency (shared, most outputs allow no less than 10 ms). '
                    'Other programs cannot play to it meanwhile; it falls back to shared when another program holds it. '
                    'Bluetooth outputs always play shared.',
              ),
            _row('Gain', _Gain(a)),
            if (!virtual) _row('Level', _LevelBars(widget.ctl)),
            const SizedBox(height: Space.xs),
            _StatusLine(widget.ctl),
            if (!virtual) ...[const SizedBox(height: Space.m), _RecordRow(widget.ctl)],
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

String _ms(double v) => v.toStringAsFixed(1);

/// A quiet line under a row: a 6 px pip and small text (accent for a warning).
class _Hint extends StatelessWidget {
  final String text;
  final bool warn;
  const _Hint(this.text, {this.warn = false});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 84, bottom: Space.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 5), child: Pip(warn ? Pal.accent : Pal.text3, size: 6)),
        const SizedBox(width: Space.s),
        Expanded(
          child: Text(text, key: const Key('audio-output-hint'), style: ui(TypeSize.small, color: warn ? Pal.text1 : Pal.text2)),
        ),
      ],
    ),
  );
}

/// Under the buffer: what Auto chose and why (small text3), or nothing for a manual size.
class _AutoLine extends StatelessWidget {
  final AppController ctl;
  const _AutoLine(this.ctl);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctl.audioLevels,
    builder: (context, _) {
      final a = ctl.audio;
      if (!a.prefs.isAuto) return const SizedBox.shrink();
      final st = a.st;
      final dev = a.playing && st.playbackBuffer > 0 && st.playbackRate > 0
          ? ' · the output wakes every ${_ms(st.playbackBuffer / st.playbackRate * 1000)} ms'
          : '';
      final phase = a.autoBuffer.phase;
      return Padding(
        padding: const EdgeInsets.only(left: 84, bottom: Space.xs),
        child: Text(
          'Recommended · now ${a.period} frames$dev${phase.isNotEmpty ? ' · $phase' : ''}',
          key: const Key('audio-auto-line'),
          style: ui(TypeSize.small, color: Pal.text3),
        ),
      );
    },
  );
}

/// Under the Striso buffer: the board's ring as it reports it (small text3).
class _BoardLine extends StatelessWidget {
  final AppController ctl;
  const _BoardLine(this.ctl);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctl.audioLevels,
    builder: (context, _) {
      final a = ctl.audio;
      final b = a.board;
      final t = b?.ringTarget ?? a.boardTargetWanted;
      final low = b?.ringMin;
      return Padding(
        padding: const EdgeInsets.only(left: 84, bottom: Space.xs),
        child: Text(
          '${a.prefs.boardBuffer == AudioPrefs.auto ? 'Recommended · ' : ''}now $t frames (${(t / 48).toStringAsFixed(2)} ms)'
          '${low != null ? ' · lowest before a packet $low' : ''}',
          key: const Key('audio-board-line'),
          style: ui(TypeSize.small, color: Pal.text3),
        ),
      );
    },
  );
}

/// The total through the computer and, always next to it in micro type, its parts.
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
      final b = a.breakdown;
      final inRate = st.captureRate > 0 ? st.captureRate : 48000, outRate = st.playbackRate > 0 ? st.playbackRate : 48000;
      String per(int min, int def, int rate) => min > 0 ? '${_ms(min / rate * 1000)} ms minimum, ${_ms(def / rate * 1000)} ms default' : 'not reported';
      final tip = on
          ? [
              'Through the computer, ${_ms(b.total)} ms:',
              '· input ${_ms(b.input)} ms: half its ${_ms(st.capNominalUs / 1000)} ms wake-up interval'
                  '${Platform.isWindows ? (st.captureExclusive ? ' + about 1 ms the USB driver adds (measured)' : '') : (st.captureStreamLatency > 0 ? ' + ${_ms(st.captureStreamLatency / inRate * 1000)} ms the system reports' : '')}',
              '· ring ${_ms(b.ring)} ms: the passthrough (it aims at ${_ms(st.targetMs)} ms; margin ${_ms(st.marginMs)} ms)',
              '· output ${_ms(b.output)} ms: ${st.playbackBuffer} frames per wake-up${st.playbackExclusive ? ' (exclusive)' : ' (shared)'}'
                  '${st.playbackClock ? ', measured by the output’s own clock' : (st.playbackStreamLatency > 0 ? ' + ${_ms(st.playbackStreamLatency / outRate * 1000)} ms the system reports' : '')}',
              '· USB ${_ms(b.usb)} ms: the board’s ring before each 1 ms packet, ${b.usbMeasured ? 'as it reports it' : 'its target (estimated)'}',
              'Device periods: input ${per(st.captureDevMin, st.captureDevDefault, inRate)}; output ${per(st.playbackDevMin, st.playbackDevDefault, outRate)}.',
              'The synth itself adds its block before USB, as at the headphone jack. Clock drift corrected: ${st.driftPpm.toStringAsFixed(0)} ppm.',
            ].join('\n')
          : 'The latency shows while Through PC plays';
      return Tooltip(
        message: tip,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(on ? '${_ms(b.total)} ms' : '–', key: const Key('audio-latency'), style: ui(TypeSize.body)),
            if (on) ...[
              const SizedBox(height: 2),
              Text(
                'in ${_ms(b.input)} · ring ${_ms(b.ring)} · out ${_ms(b.output)} · usb ${b.usbMeasured ? '' : '~'}${_ms(b.usb)}'.toUpperCase(),
                key: const Key('audio-breakdown'),
                style: microStyle(color: Pal.text3),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// "0 in the last minute" and where they happened: board · input · output.
class _Dropouts extends StatelessWidget {
  final AppController ctl;
  const _Dropouts(this.ctl);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctl.audioLevels,
    builder: (context, _) {
      final a = ctl.audio;
      if (!a.playing) return Text('–', style: ui(TypeSize.body, color: Pal.text3));
      final m = a.dropoutsLastMinute();
      final n = m.values.fold(0, (x, y) => x + y);
      final st = a.st;
      final tip = [
        'Dropouts heard in the last minute, by where they happened:',
        '· board: its ring ran dry or overflowed (its own counters, read every 2 s)',
        '· input: the Striso’s audio reached the computer late, or the ring was full',
        '· output: the output woke up late, or took more than the ring held',
        'Input wakes every ${_ms(st.capNominalUs / 1000)} ms (longest ${_ms(st.capRecentGapUs / 1000)} ms lately, ${st.inLate} late); '
            'output every ${_ms(st.playNominalUs / 1000)} ms (longest ${_ms(st.playRecentGapUs / 1000)} ms, ${st.outLate} late).',
        'Threads: input ${RtFlags.text(st.rtCapture)}; output ${RtFlags.text(st.rtPlayback)}. Each dropout is in the console with its cause.',
      ].join('\n');
      return Tooltip(
        message: tip,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$n in the last minute', key: const Key('audio-dropouts'), style: ui(TypeSize.body, color: n > 0 ? Pal.text1 : Pal.text2)),
            const SizedBox(height: 2),
            Text(
              'board ${m[DropSide.board]} · input ${m[DropSide.input]} · output ${m[DropSide.output]}'.toUpperCase(),
              key: const Key('audio-dropouts-by-side'),
              style: microStyle(color: Pal.text3),
            ),
          ],
        ),
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
              child: Text(live, style: ui(TypeSize.small, color: Pal.text3)),
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
