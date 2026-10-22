// The top bar (brand, now playing, synth CPU, connection), the banner, toasts and dialogs.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';

class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 26});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _BrandPainter());
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 32;
    void dot(double x, double y, double r, Color col) => c.drawCircle(Offset(x * k, y * k), r * k, Paint()..color = col);
    dot(11, 12, 5, Pal.honey);
    dot(21, 9, 4, Pal.honey.withValues(alpha: 0.55));
    dot(21, 21, 5, Pal.ember);
    dot(11, 24, 3.5, Pal.honey.withValues(alpha: 0.4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class TopBar extends StatelessWidget {
  final AppController ctl;
  const TopBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1B1828), Color(0xFF17141F)]),
        border: Border(bottom: BorderSide(color: Pal.seam)),
      ),
      child: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 1000;
            final l = ctl.load;
            final cpuColor = l == null ? Pal.text : (l.peakPct > 85 ? Pal.danger : (l.peakPct > 60 ? Pal.honey : Pal.text));
            return Row(
              children: [
                const BrandMark(),
                const SizedBox(width: 10),
                if (box.maxWidth >= 700)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Striso',
                          style: ui(19, color: Pal.honey, weight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: ' Live',
                          style: ui(19, weight: FontWeight.w300),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(width: 22),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      if (ctl.nowEngine.isNotEmpty && box.maxWidth >= 760) ...[
                        Flexible(child: Text(ctl.nowEngine, maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(15, color: Pal.muted))),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          ctl.nowPreset,
                          key: const Key('now-preset'),
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            24,
                            color: ctl.voiceName.isEmpty ? Pal.faint : Pal.honey,
                            weight: ctl.voiceName.isEmpty ? FontWeight.w300 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!narrow) const SizedBox(width: 22),
                if (!narrow)
                  Tooltip(
                    message: l == null
                        ? (ctl.loadNa
                              ? 'This firmware does not report synth load (no L command).'
                              : 'Synth DSP load, read from the board every second')
                        : 'Synth DSP load over the last second: ${l.blocks} blocks, avg ${l.avg} and peak ${l.peak} of ${l.budget} cycles per block',
                    child: Row(
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Synth CPU', style: ui(12, color: Pal.muted)),
                            Text.rich(
                              TextSpan(
                                style: ui(12, color: Pal.muted),
                                children: [
                                  const TextSpan(text: 'avg '),
                                  TextSpan(
                                    text: l != null ? '${l.avgPct.toStringAsFixed(0)}%' : (ctl.loadNa ? 'n/a' : '–'),
                                    style: ui(15, color: cpuColor, weight: FontWeight.w600),
                                  ),
                                  if (!ctl.loadNa) TextSpan(text: ' peak ${l != null ? '${l.peakPct.toStringAsFixed(0)}%' : '–'}'),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        SizedBox(width: 120, height: 34, child: CustomPaint(painter: _LoadPainter(List.of(ctl.loadHist)))),
                      ],
                    ),
                  ),
                const SizedBox(width: 22),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusDot(ctl.dot),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(ctl.status, key: const Key('status'), overflow: TextOverflow.ellipsis, style: ui(13)),
                          ),
                        ],
                      ),
                      if (ctl.version != null)
                        Tooltip(
                          message: [ctl.version!.line, ...ctl.version!.extra].join('\n'),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 300),
                            child: Text(
                              ctl.version!.fw,
                              overflow: TextOverflow.ellipsis,
                              style: ui(11.5, color: Pal.faint),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Btn(ctl.connectLabel, key: const Key('btn-connect'), kind: BtnKind.primary, onPressed: ctl.connecting ? null : ctl.connectButton),
              ],
            );
          },
        ),
      ),
    );
  }
}

class StatusDot extends StatefulWidget {
  final Dot dot;
  const StatusDot(this.dot, {super.key});
  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  void _sync() {
    if (widget.dot == Dot.busy) {
      if (!_a.isAnimating) _a.repeat(reverse: true);
    } else {
      _a.stop();
      _a.value = 0;
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final col = switch (widget.dot) {
      Dot.on => Pal.ok,
      Dot.demo => Pal.glacier,
      Dot.busy => Pal.honey,
      Dot.off => Pal.faint,
    };
    return AnimatedBuilder(
      animation: _a,
      builder: (_, _) => Opacity(
        opacity: 1 - 0.7 * _a.value,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: col,
            shape: BoxShape.circle,
            boxShadow: widget.dot == Dot.on || widget.dot == Dot.demo ? [BoxShadow(color: col, blurRadius: 8)] : null,
          ),
        ),
      ),
    );
  }
}

class _LoadPainter extends CustomPainter {
  final List<LoadReading> h;
  _LoadPainter(this.h);

  @override
  void paint(Canvas g, Size s) {
    final w = s.width, hh = s.height;
    g.drawRect(Offset.zero & s, Paint()..color = const Color.fromRGBO(160, 150, 200, 0.08));
    final dash = Paint()
      ..color = const Color.fromRGBO(255, 122, 122, 0.35)
      ..strokeWidth = 1;
    for (var x = 0.0; x < w; x += 6) {
      g.drawLine(Offset(x, hh * 0.15), Offset(math.min(w, x + 3), hh * 0.15), dash);
    }
    if (h.isEmpty) return;
    const n = 90;
    final dx = w / (n - 1);
    double x(int i) => w - (h.length - 1 - i) * dx;
    double y(double pct) => hh - math.min(1, pct / 100) * hh;
    final area = Path()..moveTo(x(0), hh);
    for (var i = 0; i < h.length; i++) {
      area.lineTo(x(i), y(h[i].avgPct));
    }
    area
      ..lineTo(x(h.length - 1), hh)
      ..close();
    g.drawPath(area, Paint()..color = const Color.fromRGBO(244, 210, 122, 0.35));
    final peak = Path();
    for (var i = 0; i < h.length; i++) {
      i == 0 ? peak.moveTo(x(i), y(h[i].peakPct)) : peak.lineTo(x(i), y(h[i].peakPct));
    }
    g.drawPath(
      peak,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Pal.ember,
    );
  }

  @override
  bool shouldRepaint(covariant _LoadPainter old) => true;
}

class BannerBar extends StatelessWidget {
  final AppController ctl;
  const BannerBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final b = ctl.banner;
        if (b == null) return const SizedBox.shrink();
        return Container(
          key: const Key('banner'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: b.info ? const Color(0xFF1D2C35) : const Color(0xFF3A1F2A),
            border: Border(bottom: BorderSide(color: b.info ? const Color(0xFF2C4A57) : const Color(0xFF5B2C3C))),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(b.text, style: ui(14, color: b.info ? const Color(0xFFD5F4FB) : const Color(0xFFFFD9D9))),
              ),
              const SizedBox(width: 12),
              Btn('Dismiss', small: true, onPressed: ctl.hideBanner),
            ],
          ),
        );
      },
    );
  }
}

class ToastLayer extends StatelessWidget {
  final AppController ctl;
  const ToastLayer(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<List<ToastMsg>>(
        valueListenable: ctl.toasts,
        builder: (context, list, _) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in list)
                  Padding(
                    key: ValueKey(t.id),
                    padding: const EdgeInsets.only(top: 6),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 180),
                      builder: (_, v, child) => Opacity(
                        opacity: v,
                        child: Transform.translate(offset: Offset(0, 6 * (1 - v)), child: child),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2540),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: t.kind == 'warn' ? Pal.honey : (t.kind == 'error' ? Pal.danger : Pal.line)),
                          boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8))],
                        ),
                        child: Text(t.text, style: ui(13.5, color: t.kind == 'error' ? const Color(0xFFFFD9D9) : Pal.text)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// dialogs

Future<bool> confirmSave(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => _Dialog(
      title: 'Save touch settings to the Striso?',
      body: Text(
        'The app lets go of the board, the settings are written to it and it restarts (about 15 seconds), then the app '
        'reconnects and reads them back. The previous settings are backed up on this computer first.',
        style: ui(13, color: Pal.muted),
      ),
      actions: [
        Btn('Cancel', onPressed: () => Navigator.pop(ctx, false)),
        Btn('Save', key: const Key('dlg-save-go'), kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return r == true;
}

Future<void> showCode(BuildContext context, AppController ctl, Preset p) async {
  final text = presetToC(p);
  await Clipboard.setData(ClipboardData(text: text));
  ctl.toast('Copied to the clipboard');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _Dialog(
      title: 'C code for "${p.name}"',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Arrays in parameter index order with names, for the firmware preset tables.', style: ui(13, color: Pal.muted)),
          const SizedBox(height: 10),
          Container(
            height: 360,
            decoration: BoxDecoration(
              color: Pal.ink,
              border: Border.all(color: Pal.line),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(10),
            child: SingleChildScrollView(
              child: SelectableText(text, style: mono(12, color: const Color(0xFFE8E2F5))),
            ),
          ),
        ],
      ),
      actions: [
        Btn(
          'Copy',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            ctl.toast('Copied to the clipboard');
          },
        ),
        Btn('Done', kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
}

Future<bool> showSuggest(BuildContext context, Suggestion r) async {
  final rows = [...r.changes]..sort((a, b) => a.key.n - b.key.n);
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => _Dialog(
      title: 'Suggested key factors',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Brings the ${r.used} keys you pressed to their middle peak ${r.median!.toStringAsFixed(2)}. '
            'Keys you did not press stay as they are; factors stay between 0.6 and 1.6.'
            '${r.skipped.isNotEmpty ? ' ${r.skipped.length} press${r.skipped.length == 1 ? ' was' : 'es were'} too light or too hard to use.' : ''}',
            style: ui(13, color: Pal.muted),
          ),
          const SizedBox(height: 10),
          Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            decoration: BoxDecoration(
              border: Border.all(color: Pal.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: Table(
                columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth(1.2)},
                children: [
                  TableRow(
                    children: [
                      for (final (i, h) in ['Key', 'Last peak', 'Factor now', 'Suggested'].indexed) _cell(h, i == 0, Pal.muted),
                    ],
                  ),
                  for (final c in rows)
                    TableRow(
                      children: [
                        _cell(c.key.name, true, Pal.text),
                        _cell(c.key.peak.toStringAsFixed(2), false, Pal.text),
                        _cell('×${c.key.factor.toStringAsFixed(2)}', false, Pal.text),
                        _cell(
                          '×${c.to.toStringAsFixed(2)}${c.clamped ? ' (limit)' : ''}',
                          false,
                          c.to > c.key.factor ? const Color(0xFFFFB39D) : const Color(0xFFA9C4FF),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        Btn('Cancel', onPressed: () => Navigator.pop(ctx, false)),
        Btn('Apply', key: const Key('dlg-suggest-apply'), kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return res == true;
}

Widget _cell(String t, bool left, Color c) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
  decoration: const BoxDecoration(
    border: Border(bottom: BorderSide(color: Pal.seam)),
  ),
  child: Text(
    t,
    textAlign: left ? TextAlign.left : TextAlign.right,
    style: ui(13, color: c),
  ),
);

class _Dialog extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  const _Dialog({required this.title, required this.body, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Pal.panel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ui(17, weight: FontWeight.w600)),
              const SizedBox(height: 8),
              body,
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
