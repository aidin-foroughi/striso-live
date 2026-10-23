// The instrument (DESIGN.md 4.1 and 5): a dark plate with slightly lighter discs at rest, light
// while playing. Scale shows in rims and label strength, never fills; pressure is a warm fill
// from the tilt point with a halo; one thrown ring per strike. Overlays: the key equalizer and
// the settings keys. A static picture holds what does not move. Port of tools/app/js/board.js.

import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'paint_util.dart';

final List<(int, int, int)> _heat = () {
  const stops = BoardPal.heatStops;
  final out = <(int, int, int)>[];
  for (var k = 0; k < 64; k++) {
    final t = k / 63;
    var j = 0;
    while (j < stops.length - 2 && t > stops[j + 1].$1) {
      j++;
    }
    final (t0, a) = stops[j];
    final (t1, b) = stops[j + 1];
    final f = ((t - t0) / (t1 - t0)).clamp(0.0, 1.0);
    out.add(((a[0] + (b[0] - a[0]) * f).round(), (a[1] + (b[1] - a[1]) * f).round(), (a[2] + (b[2] - a[2]) * f).round()));
  }
  return out;
}();

Color _heatOf(double p, [double a = 1]) {
  final c = _heat[(p * 63).round().clamp(0, 63)];
  return Color.fromRGBO(c.$1, c.$2, c.$3, a.clamp(0.0, 1.0));
}

Color _a(Color c, double a) => c.withValues(alpha: a.clamp(0.0, 1.0));
Color _lighter(Color c, double by) => Color.lerp(c, Colors.white, by)!;

/// The smoothed key display state, advanced once per frame; also holds the static picture.
class BoardAnim {
  final dp = List<double>.filled(buttonCount, 0), dx = List<double>.filled(buttonCount, 0), dy = List<double>.filled(buttonCount, 0);
  double lastDraw = -1e9;
  bool force = true;
  dui.Picture? picture;
  String signature = '';

  /// Returns true when something moves (the board must repaint).
  bool step(LiveState live, double now, double dt, {required bool hovering, bool direct = false}) {
    final kUp = direct ? 1.0 : 1 - math.exp(-dt / 16), kDown = direct ? 1.0 : 1 - math.exp(-dt / 110), kXY = 1 - math.exp(-dt / 30);
    var busy = hovering || now - lastDraw > 1000;
    for (final id in keyIds) {
      final target = math.min(1.0, live.pres[id].toDouble());
      final d = dp[id];
      dp[id] = d + (target - d) * (target > d ? kUp : kDown);
      if (dp[id] < 0.002 && target == 0) dp[id] = 0;
      dx[id] += (live.x[id] - dx[id]) * kXY;
      dy[id] += (live.y[id] - dy[id]) * kXY;
      if (dp[id] > 0 || now - live.strikeT[id] < 450) busy = true;
    }
    for (var i = 0; i < 4; i++) {
      if (live.controls[i] == 1 || now - live.controlT[i] < 300) busy = true;
    }
    return busy;
  }

  void dispose() {
    picture?.dispose();
    picture = null;
  }
}

class _Geo {
  final double s, ox, oy;
  const _Geo(this.s, this.ox, this.oy);
  factory _Geo.of(Size size) {
    final pw = plate.x1 - plate.x0, ph = plate.y1 - plate.y0;
    const pad = 8.0;
    final s = math.max(0.01, math.min((size.width - 2 * pad) / pw, (size.height - 2 * pad) / ph));
    return _Geo(s, size.width / 2 - ((plate.x0 + plate.x1) / 2) * s, size.height / 2 + ((plate.y0 + plate.y1) / 2) * s);
  }
  double px(double x) => ox + x * s;
  double py(double y) => oy - y * s;
  Offset at(double x, double y) => Offset(px(x), py(y));
}

/// The board. [overlays]: the Setup tab's key equalizer and settings-keys overlays; without them
/// a click on a key only selects it for the key equalizer. [labelScale]: bigger labels (stage).
class BoardView extends StatefulWidget {
  final AppController ctl;
  final bool overlays;
  final double labelScale;
  const BoardView(this.ctl, {super.key, this.overlays = false, this.labelScale = 1});

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _Pointer {
  final int? key, control;
  final double t0;
  double x, y;
  _Pointer({this.key, this.control, this.t0 = 0, this.x = 0, this.y = 0});
}

class _BoardViewState extends State<BoardView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final anim = BoardAnim();
  final _repaint = Pulse();
  final _pointers = <int, _Pointer>{};
  Duration _last = Duration.zero;
  Size _size = Size.zero;

  AppController get ctl => widget.ctl;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    anim.dispose();
    super.dispose();
  }

  bool get _reduced => ctl.options.reducedMotion || (mounted && MediaQuery.maybeDisableAnimationsOf(context) == true);

  void _tick(Duration t) {
    final dt = math.min(100.0, (t - _last).inMicroseconds / 1000);
    _last = t;
    final now = clockMs();
    _updatePlaying(now);
    final busy =
        anim.step(ctl.live, now, dt, hovering: ctl.hover >= 0 || _pointers.isNotEmpty, direct: _reduced) ||
        now - ctl.waveT < Timing.sweep.inMilliseconds + 400;
    if (busy || anim.force) {
      anim.force = false;
      anim.lastDraw = now;
      _repaint.ping();
    }
  }

  ({int? key, double dx, double dy, int? control})? _hit(Offset p) {
    final g = _Geo.of(_size);
    final x = (p.dx - g.ox) / g.s, y = -(p.dy - g.oy) / g.s;
    for (final k in boardKeys) {
      final dx = x - k.x, dy = y - k.y;
      if (dx * dx + dy * dy <= keyRadius * keyRadius * 1.1) return (key: k.id, dx: dx / keyRadius, dy: dy / keyRadius, control: null);
    }
    for (final c in controls) {
      if (math.sqrt(math.pow(x - c.x, 2) + math.pow(y - c.y, 2)) < 7) return (key: null, dx: 0.0, dy: 0.0, control: c.id);
    }
    return null;
  }

  void _hover(Offset p) {
    final h = _hit(p);
    final hk = h?.key ?? -1, hc = h?.control ?? -1;
    if (hk != ctl.hover || hc != ctl.hoverControl) {
      ctl.hover = hk;
      ctl.hoverControl = hc;
      ctl.stats.ping();
      anim.force = true;
    }
    final ptr = _pointers.values.where((q) => q.key != null).firstOrNull;
    if (ptr != null && h?.key == ptr.key) {
      ptr.x = h!.dx.clamp(-1, 1);
      ptr.y = h.dy.clamp(-1, 1);
    }
  }

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
    final h = _hit(e.localPosition);
    if (h?.key != null && ctl.boardSelect(h!.key!, overlays: widget.overlays)) return;
    final board = ctl.demoBoard;
    if (!ctl.playable || board == null || h == null) return;
    if (h.key != null) {
      _pointers[e.pointer] = _Pointer(key: h.key, t0: clockMs(), x: h.dx, y: h.dy);
      board.press(h.key!, pres: 0.3, x: h.dx, y: h.dy, strike: 0.7);
    } else {
      _pointers[e.pointer] = _Pointer(control: h.control);
      board.control(h.control!, true);
    }
  }

  void _up(PointerEvent e) {
    final p = _pointers.remove(e.pointer);
    final board = ctl.demoBoard;
    if (p == null || board == null) return;
    if (p.key != null) {
      board.release(p.key!, 0.25);
    } else {
      board.control(p.control!, false);
    }
  }

  // held keys swell with time
  void _updatePlaying(double now) {
    final board = ctl.demoBoard;
    if (board == null) return;
    for (final p in _pointers.values) {
      if (p.key == null) continue;
      final held = (now - p.t0) / 1000;
      final pres = math.min(0.95, 0.3 + 0.65 * (1 - math.exp(-held * 1.6)));
      board.press(p.key!, pres: pres, x: p.x, y: p.y, strike: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return MouseRegion(
          cursor: (ctl.playable || widget.overlays) && (ctl.hover >= 0 || ctl.hoverControl >= 0)
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onHover: (e) => _hover(e.localPosition),
          onExit: (_) {
            ctl.hover = -1;
            ctl.hoverControl = -1;
            ctl.stats.ping();
            anim.force = true;
          },
          child: Listener(
            onPointerDown: _down,
            onPointerMove: (e) => _hover(e.localPosition),
            onPointerUp: _up,
            onPointerCancel: _up,
            child: Semantics(
              label: 'The Striso keys, lit by pressure while you play',
              child: CustomPaint(
                size: _size,
                painter: BoardPainter(ctl, anim, _repaint, overlays: widget.overlays, labelScale: widget.labelScale, reduced: _reduced),
                isComplex: true,
                willChange: true,
              ),
            ),
          ),
        );
      },
    );
  }
}

class BoardPainter extends CustomPainter {
  final AppController ctl;
  final BoardAnim anim;
  final bool overlays, reduced;
  final double labelScale;
  BoardPainter(this.ctl, this.anim, Listenable repaint, {this.overlays = false, this.labelScale = 1, this.reduced = false})
    : super(repaint: Listenable.merge([repaint, ctl, ctl.values]));

  LiveState get live => ctl.live;
  bool get _eq => overlays && ctl.eqOn && ctl.params[3]!.params.isNotEmpty && !ctl.settingsOn;
  bool get _settings => overlays && ctl.settingsOn;
  bool get _hoverable => overlays || ctl.playable;

  String _signature(Size size) {
    final eqSig = _eq
        ? [
            for (final id in keyIds) '${ctl.keyParam(id)?.value.toStringAsFixed(3)}:${ctl.lastPeakOf(id).toStringAsFixed(3)}',
            ctl.eqMedian?.toStringAsFixed(3),
            ctl.eqSelected,
          ].join(',')
        : '';
    final setSig = _settings ? '${ctl.current}|${ctl.voices.length}|${ctl.settingsSelected}' : '';
    return '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}|${live.transpose}|${live.transposeFifths}|'
        '${ctl.currentKey?.name}|${ctl.names.name}|$labelScale|$eqSig|$setSig';
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final g = _Geo.of(size);
    final sig = _signature(size);
    if (anim.picture == null || sig != anim.signature) {
      final rec = dui.PictureRecorder();
      _buildStatic(Canvas(rec), size, g);
      anim.picture?.dispose();
      anim.picture = rec.endRecording();
      anim.signature = sig;
    }
    canvas.drawPicture(anim.picture!);
    _dynamic(canvas, g);
  }

  Paint _stroke(Color c, double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..color = c;

  /// The look of a key at rest: rim colour and width (null: none), label colour, dashed rim.
  ({Color? rim, double rimW, Color label, bool dash}) _look(KeyInfo k) {
    final key = ctl.currentKey;
    if (key == null) return (rim: null, rimW: 0, label: Pal.t(k.natural ? 0.70 : 0.42), dash: false);
    final tpc = keyTpc(k.id, live.transposeFifths);
    final rel = keyRelation(key, tpc);
    final bh = barryHarrisRole(key, tpc);
    return switch (rel) {
      KeyRelation.root => (rim: Pal.accent, rimW: 1.5, label: Pal.accent, dash: false),
      KeyRelation.rootEnharmonic => (rim: _a(Pal.accent, 0.5), rimW: 1.5, label: _a(Pal.accent, 0.7), dash: false),
      // Barry Harris: the sixth chord's tones solid, the diminished chord's dashed
      KeyRelation.inScale when bh == BarryHarrisRole.chord => (rim: Pal.t(0.42), rimW: 1.2, label: Pal.t(0.95), dash: false),
      KeyRelation.inScale when bh == BarryHarrisRole.dim => (rim: Pal.t(0.24), rimW: 1, label: Pal.t(0.68), dash: true),
      KeyRelation.inScale => (rim: Pal.t(0.18), rimW: 1, label: Pal.t(0.85), dash: false),
      KeyRelation.enharmonic => (rim: Pal.t(0.09), rimW: 1, label: Pal.t(0.6), dash: false),
      _ => (rim: null, rimW: 0, label: Pal.t(0.28), dash: false),
    };
  }

  // ---------------------------------------------------------------------------------------------
  // static layer

  void _buildStatic(Canvas c, Size size, _Geo g) {
    final s = g.s, r = keyRadius * s;
    final x0 = g.px(plate.x0), y0 = g.py(plate.y1), x1 = g.px(plate.x1), y1 = g.py(plate.y0);
    c.drawRRect(RRect.fromLTRBR(x0, y0, x1, y1, Radius.circular(plate.radius * s)), Paint()..color = BoardPal.plate);

    // the pitch axis: C labels at the right plate edge, no lines
    final t = live.transpose;
    for (var midi = 24; midi <= 108; midi += 12) {
      final y = g.py((midi - startNote - t) * mmPerSemitone);
      if (y < y0 + 6 * s || y > y1 - 4 * s) continue;
      drawText(c, 'C${midi ~/ 12 - 1}', Offset(x1 - 2 * s, y), TypeSize.micro, Pal.text3, weight: FontWeight.w500, align: 1);
    }

    for (final k in boardKeys) {
      final center = g.at(k.x, k.y);
      c.drawCircle(center, r, Paint()..color = k.natural ? BoardPal.natural : BoardPal.accidental);
      final l = _look(k);
      if (l.rim != null) {
        final p = _stroke(l.rim!, l.rimW);
        l.dash ? dashedCircle(c, center, r - l.rimW / 2, p, s * 1.1, s * 0.9) : c.drawCircle(center, r - l.rimW / 2, p);
      }
      _label(c, k, center.dx, center.dy, r, l.label, size.width);
    }

    if (_eq) _drawEq(c, g, r);
    if (_settings) _drawSettings(c, g, r);
    for (final b in controls) {
      _control(c, g, b, 0);
    }
  }

  void _label(Canvas c, KeyInfo k, double cx, double cy, double r, Color col, double boardWidth) {
    var mode = ctl.names;
    if (mode == Names.off) return;
    // under 700 px the octave digits go
    if (mode == Names.octave && boardWidth < 700) mode = Names.letters;
    final n = noteName(k.id, live.transpose, live.transposeFifths);
    final big = math.max(11.0, r * 0.72 * labelScale).roundToDouble();
    final key = ctl.currentKey;
    if (key != null && (mode == Names.degrees || mode == Names.solfege)) {
      final tpc = keyTpc(k.id, live.transposeFifths);
      final text = mode == Names.degrees ? degreeLabel(key, tpc) : solfege(key, tpc);
      drawText(c, text, Offset(cx, cy), text.length > 2 ? math.max(11.0, big * 0.85) : big, col, weight: FontWeight.w500);
      return;
    }
    if (mode != Names.octave) {
      drawText(c, n.text, Offset(cx, cy), big, col, weight: FontWeight.w500);
      return;
    }
    final small = math.max(9.0, r * 0.4 * labelScale).roundToDouble();
    final w = textWidth(n.text, big, weight: FontWeight.w500);
    final left = cx - (w + 2 + small * 0.6) / 2;
    drawText(c, n.text, Offset(left, cy), big, col, weight: FontWeight.w500, align: -1);
    // the octave digit, baseline-aligned, 2 px right of the name
    drawText(c, '${n.octave}', Offset(left + w + 2, cy + big * 0.36), small, col, weight: FontWeight.w500, align: -1, vAlign: 1);
  }

  // the key equalizer: per key the factor as a tint (warm > 1, demo blue < 1) and value, the last
  // press's peak as an arc against the median of the measured keys
  void _drawEq(Canvas c, _Geo g, double r) {
    final med = ctl.eqMedian;
    for (final k in boardKeys) {
      final center = g.at(k.x, k.y);
      final f = ctl.keyParam(k.id)?.value;
      if (f != null && (math.log(f) / math.ln2).abs() > 0.004) {
        final a = 0.5 * math.min(1.0, 1.6 * (math.log(f) / math.ln2).abs());
        c.drawCircle(center, r, Paint()..color = _a(f > 1 ? BoardPal.heatMid : Pal.demo, a));
      }
      if (f != null && (f - 1).abs() > 0.0005) {
        drawText(c, '×${f.toStringAsFixed(2)}', Offset(center.dx, center.dy + r * 0.6), TypeSize.small, Pal.text1, weight: FontWeight.w500);
      }
      final pk = ctl.lastPeakOf(k.id);
      if (pk > 0) {
        final dev = med != null ? pk / med - 1 : 0.0;
        final col = dev.abs() < 0.08 ? Pal.ok : (dev < 0 ? Pal.demo : BoardPal.heatMid);
        final frac = med != null ? math.min(1.0, pk / (2 * med)) : math.min(1.0, pk);
        c.drawArc(
          Rect.fromCircle(center: center, radius: r + 2),
          -math.pi / 2,
          frac * math.pi * 2,
          false,
          _stroke(col, 2)..strokeCap = StrokeCap.round,
        );
        drawText(c, pk >= 1.7 ? 'max' : pk.toStringAsFixed(2), Offset(center.dx, center.dy - r * 0.58), TypeSize.small, col, weight: FontWeight.w500);
      }
      if (k.id == ctl.eqSelected) c.drawCircle(center, r + 3, _stroke(Pal.accent, 2));
    }
  }

  // what each key does with the Settings button held
  void _drawSettings(Canvas c, _Geo g, double r) {
    final s = g.s;
    final voices = ctl.settingsVoices();
    for (final k in boardKeys) {
      final center = g.at(k.x, k.y);
      final f = settingsKeys[k.id];
      if (f == null) {
        c.drawCircle(center, r + 0.5, Paint()..color = _a(Pal.bg0, 0.78));
        continue;
      }
      final v = f.engine != null ? voices[f.engine] : null;
      final col = f.engine != null ? engineColor(f.engine!) : (f.danger ? Pal.error : rgb(groupColors[f.group] ?? 0xffffff));
      c.drawCircle(center, r, Paint()..color = BoardPal.natural);
      if (v != null && v.current) c.drawCircle(center, r, Paint()..color = _a(col, 0.15));
      final rim = _stroke(v != null && v.count == 0 ? _a(col, 0.3) : col, 1.5);
      f.uncertain ? dashedCircle(c, center, r - 0.75, rim, s * 1.2, s * 0.8) : c.drawCircle(center, r - 0.75, rim);
      if (k.id == ctl.settingsSelected) c.drawCircle(center, r + 3, _stroke(Pal.accent, 2));
      final label = f.short + (f.uncertain ? '?' : '');
      final size = math.max(10.0, r * (label.length > 5 ? 0.4 : (label.length > 3 ? 0.48 : 0.58))).roundToDouble();
      drawText(c, label, Offset(center.dx, center.dy - (v != null ? r * 0.16 : 0)), size, f.danger ? Pal.error : Pal.text1, weight: FontWeight.w500);
      if (v != null) {
        final sub = v.count == 0 ? 'not here' : (v.current && v.preset.isNotEmpty ? v.preset : (v.count > 1 ? '${v.count} presets' : ''));
        drawText(
          c,
          sub.length > 11 ? '${sub.substring(0, 10)}…' : sub,
          Offset(center.dx, center.dy + r * 0.38),
          math.max(9.0, r * 0.3).roundToDouble(),
          v.count > 0 ? Pal.text2 : Pal.text3,
          weight: FontWeight.w400,
        );
      }
    }
    // the button to hold
    final set = controls.firstWhere((b) => b.id == 3);
    c.drawCircle(g.at(set.x, set.y), 8.5 * s, _stroke(Pal.accent, 1.5));
    drawText(c, 'hold', Offset(g.px(set.x), g.py(set.y) + 9.5 * s), TypeSize.micro, Pal.accent, weight: FontWeight.w500, vAlign: -1);
  }

  /// A control button: outline text1 @ 30%; lit: accent fill @ 35% and accent outline.
  void _control(Canvas c, _Geo g, ControlButton b, double lit) {
    final s = g.s, cx = g.px(b.x), cy = g.py(b.y), r = 5.2 * s;
    final path = Path();
    switch (b.shape) {
      case ControlShape.ring:
        path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.15));
      case ControlShape.square:
        path.addRRect(RRect.fromLTRBR(cx - r, cy - r, cx + r, cy + r, Radius.circular(r * 0.3)));
      case ControlShape.up:
        path
          ..moveTo(cx, cy - r * 1.25)
          ..quadraticBezierTo(cx + r * 1.1, cy - r * 0.2, cx + r * 1.2, cy + r * 0.8)
          ..lineTo(cx - r * 1.2, cy + r * 0.8)
          ..quadraticBezierTo(cx - r * 1.1, cy - r * 0.2, cx, cy - r * 1.25)
          ..close();
      case ControlShape.down:
        path
          ..moveTo(cx, cy + r * 1.25)
          ..quadraticBezierTo(cx + r * 1.1, cy + r * 0.2, cx + r * 1.2, cy - r * 0.8)
          ..lineTo(cx - r * 1.2, cy - r * 0.8)
          ..quadraticBezierTo(cx - r * 1.1, cy + r * 0.2, cx, cy + r * 1.25)
          ..close();
    }
    if (lit > 0) c.drawPath(path, Paint()..color = _a(Pal.accent, 0.35 * lit));
    c.drawPath(path, _stroke(Color.lerp(Pal.t(0.3), Pal.accent, lit)!, 1));
  }

  // ---------------------------------------------------------------------------------------------
  // moving layer

  void _dynamic(Canvas c, _Geo g) {
    final s = g.s, r = keyRadius * s;
    final now = clockMs();
    final sweepAge = now - ctl.waveT;
    final lit = [
      for (final id in keyIds)
        if (anim.dp[id] > 0) id,
    ].length;
    final halos = lit <= 20;
    for (final k in boardKeys) {
      final id = k.id;
      final center = g.at(k.x, k.y);
      final p = anim.dp[id];
      final tx = anim.dx[id].clamp(-1.0, 1.0), ty = anim.dy[id].clamp(-1.0, 1.0);
      final sAge = now - live.strikeT[id];
      // the connect sweep: label brightness ripples left to right once
      var w = 0.0;
      if (!reduced && sweepAge < Timing.sweep.inMilliseconds + 300) {
        final t = (sweepAge - ((k.x + 90) / 180) * Timing.sweep.inMilliseconds) / 300;
        w = t > 0 && t < 1 ? math.sin(t * math.pi) : 0;
      }
      final hovered = id == ctl.hover && _hoverable;
      if (p <= 0 && sAge > 450 && w <= 0 && !hovered) continue;

      if (hovered && p <= 0) {
        c.drawCircle(center, r, Paint()..color = _lighter(k.natural ? BoardPal.natural : BoardPal.accidental, 0.04));
        c.drawCircle(center, r - 0.5, _stroke(Pal.text2, 1));
        _label(c, k, center.dx, center.dy, r, _look(k).label, g.s * (plate.x1 - plate.x0));
      }
      if (p > 0) {
        final gp = Offset(center.dx + tx * r * 0.4, center.dy - ty * r * 0.4);
        if (halos) {
          final halo = r * (1 + 0.6 * math.sqrt(p));
          c.drawCircle(gp, halo, Paint()..shader = ring(gp, r * 0.6, halo, [_heatOf(p, 0.25 * p), _heatOf(p, 0)]));
        }
        c.drawCircle(center, r, Paint()..color = BoardPal.natural);
        c.save();
        c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
        final fr = r * (0.5 + 1.2 * math.sqrt(p));
        final a = 0.25 + 0.75 * p;
        c.drawRect(
          Rect.fromCircle(center: center, radius: r),
          Paint()..shader = dui.Gradient.radial(gp, fr, [_heatOf(math.min(1, p * 1.2), a), _heatOf(p, a * 0.85), _heatOf(p, a * 0.35)], [0, 0.6, 1]),
        );
        c.restore();
        c.drawCircle(center, r - 0.75, _stroke(_heatOf(p), 1.5));
        _label(c, k, center.dx, center.dy, r, p < 0.35 ? Pal.text1 : _a(Pal.accentInk, 0.85), g.s * (plate.x1 - plate.x0));
        // tilt: a dot at the tilt point
        c.drawCircle(gp, 1.5, Paint()..color = _a(BoardPal.tiltDot, 0.9));
      } else if (w > 0) {
        _label(c, k, center.dx, center.dy, r, _a(Pal.text1, 0.4 + 0.6 * w), g.s * (plate.x1 - plate.x0));
      }
      // strike: one ring thrown out, scaled by velocity
      if (sAge < 450 && !reduced) {
        final t = sAge / 450, a = live.strikeA[id].clamp(0.0, 1.0);
        final e = 1 - math.pow(1 - t, 3);
        final rad = r * (1.0 + (0.5 + 0.6 * a) * e);
        final width = 2.5 * a * (1 - t);
        if (width > 0.05) c.drawCircle(center, rad, _stroke(_a(BoardPal.strike, 0.9 * a * (1 - t)), width));
      }
      if (id == ctl.hover && p > 0 && _hoverable) c.drawCircle(center, r + 1.5, _stroke(Pal.text2, 1));
    }
    for (final b in controls) {
      final on = live.controls[b.id] == 1;
      final age = now - live.controlT[b.id];
      final glow = on ? 1.0 : math.max(0.0, 1 - age / 300);
      if (glow > 0) _control(c, g, b, glow);
      if (b.id == ctl.hoverControl && _hoverable) c.drawCircle(g.at(b.x, b.y), 7.4 * s, _stroke(Pal.text2, 1));
    }
    // indicator LED
    c.drawCircle(g.at(ledPosition.x, ledPosition.y), 3, Paint()..color = ctl.ledOn ? Pal.ok : BoardPal.ledOff);
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) => true;
}

// ---------------------------------------------------------------------------------------------
// motion sensor: tilt disc and three rotation bars

class MotionView extends StatefulWidget {
  final AppController ctl;
  const MotionView(this.ctl, {super.key});

  @override
  State<MotionView> createState() => _MotionViewState();
}

class _MotionViewState extends State<MotionView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _repaint = Pulse();
  double bx = 0, by = 0;
  Duration _last = Duration.zero;
  bool _wasEmpty = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((t) {
      final dt = math.min(100.0, (t - _last).inMicroseconds / 1000);
      _last = t;
      final m = widget.ctl.live.motion;
      final has = clockMs() - m.t < 1500;
      if (!has && _wasEmpty) return;
      _wasEmpty = !has;
      final a = math.max(0.05, math.sqrt(m.ax * m.ax + m.ay * m.ay + m.az * m.az));
      final tx = has ? ((m.ax / a) * 2).clamp(-1.0, 1.0) : 0.0;
      final ty = has ? ((m.ay / a) * 2).clamp(-1.0, 1.0) : 0.0;
      final k = 1 - math.exp(-dt / 40);
      bx += (tx - bx) * k;
      by += (ty - by) * k;
      _repaint.ping();
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Motion sensor: tilt and rotation',
    child: CustomPaint(painter: _MotionPainter(this, _repaint), size: Size.infinite),
  );
}

class _MotionPainter extends CustomPainter {
  final _MotionViewState st;
  _MotionPainter(this.st, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas g, Size size) {
    final m = st.widget.ctl.live.motion;
    final has = clockMs() - m.t < 1500;
    final h = size.height;
    final rr = h / 2 - 2, cx = rr + 2, cy = h / 2;
    g.drawCircle(Offset(cx, cy), rr, Paint()..color = Pal.bg2);
    g.drawCircle(
      Offset(cx, cy),
      rr * 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Pal.bg3,
    );
    final b = Offset(cx + st.bx * rr * 0.85, cy - st.by * rr * 0.85);
    g.drawCircle(b, 5, Paint()..color = has ? Pal.text1 : Pal.text3);
    // rotation bars and the g reading
    final x0 = cx + rr + Space.l, bw = size.width - x0;
    for (final (i, ax) in ['x', 'y', 'z'].indexed) {
      final y = 10.0 + i * 18;
      drawText(g, 'rot $ax', Offset(x0, y), TypeSize.small, Pal.text3, weight: FontWeight.w400, align: -1);
      final bx0 = x0 + 40, bw2 = math.max(10.0, bw - 40);
      g.drawRRect(RRect.fromLTRBR(bx0, y - 2, bx0 + bw2, y + 2, const Radius.circular(2)), Paint()..color = Pal.bg3);
      final gv = [m.gx, m.gy, m.gz][i];
      final v = has ? (gv * 4).clamp(-1.0, 1.0) : 0.0;
      final mid = bx0 + bw2 / 2;
      g.drawRRect(
        RRect.fromLTRBR(math.min(mid, mid + v * bw2 / 2), y - 2, math.max(mid, mid + v * bw2 / 2), y + 2, const Radius.circular(2)),
        Paint()..color = Pal.text1,
      );
    }
    drawText(
      g,
      has ? '${m.abs.toStringAsFixed(2)} g' : 'no data',
      Offset(x0, 10.0 + 3 * 18),
      TypeSize.small,
      has ? Pal.text2 : Pal.text3,
      weight: FontWeight.w400,
      align: -1,
    );
  }

  @override
  bool shouldRepaint(covariant _MotionPainter old) => true;
}
