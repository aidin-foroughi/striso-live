// The instrument: the 61 keys in their real layout with pressure, tilt and strikes, the control
// buttons, the scale, key equalizer and settings overlays, and the motion sensor. A static layer
// (a recorded picture) holds what does not move. Port of tools/app/js/board.js.

import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'paint_util.dart';

class _Look {
  final Color top, bottom, rim, label;
  final double rimW;
  final bool dash;
  const _Look(this.top, this.bottom, this.rim, this.rimW, this.label, [this.dash = false]);
}

// key looks for a selected scale: the root clearly, the scale subtly, the rest dimmed but legible
const _scaleLook = {
  KeyRelation.root: _Look(Color(0xFF7A6232), Color(0xFF4C3B20), Color.fromRGBO(244, 210, 122, 0.98), 0.62, Color(0xFFFFF0C8)),
  KeyRelation.rootEnharmonic: _Look(
    Color(0xFF4A3F3A),
    Color(0xFF352C34),
    Color.fromRGBO(244, 210, 122, 0.6),
    0.42,
    Color.fromRGBO(255, 236, 190, 0.85),
    true,
  ),
  KeyRelation.inScale: _Look(Color(0xFF4A3F5E), Color(0xFF352D4A), Color.fromRGBO(244, 210, 122, 0.5), 0.36, Color.fromRGBO(246, 238, 218, 0.94)),
  KeyRelation.enharmonic: _Look(
    Color(0xFF2D2840),
    Color(0xFF241F35),
    Color.fromRGBO(244, 210, 122, 0.3),
    0.3,
    Color.fromRGBO(220, 210, 235, 0.6),
    true,
  ),
  KeyRelation.out: _Look(Color(0xFF201C2E), Color(0xFF1A1726), Color.fromRGBO(160, 150, 200, 0.14), 0.28, Color.fromRGBO(170, 160, 205, 0.42)),
};

class _P {
  static const plateTop = Color(0xFF26213A), plateBottom = Color(0xFF1B1829), plateEdge = Color.fromRGBO(244, 210, 122, 0.16);
  static const natural = Color(0xFF302A44), naturalRim = Color.fromRGBO(244, 210, 122, 0.42);
  static const accidental = Color(0xFF1E1A2C), accidentalRim = Color.fromRGBO(244, 210, 122, 0.18);
  static const labelNatural = Color.fromRGBO(240, 230, 205, 0.82), labelAccidental = Color.fromRGBO(190, 180, 215, 0.62);
  static const guide = Color.fromRGBO(160, 150, 200, 0.10), guideLabel = Color.fromRGBO(170, 160, 205, 0.45);
  static const control = Color(0xFF2A2540), controlRim = Color.fromRGBO(244, 210, 122, 0.35);
}

// pressure heat: honey -> ember -> rose-white
final List<(int, int, int)> _heat = () {
  const stops = [
    (0.0, [244, 210, 122]),
    (0.45, [255, 150, 84]),
    (0.75, [255, 98, 110]),
    (1.0, [255, 226, 236]),
  ];
  final out = <(int, int, int)>[];
  for (var k = 0; k < 64; k++) {
    final t = k / 63;
    var j = 0;
    while (j < stops.length - 2 && t > stops[j + 1].$1) {
      j++;
    }
    final (t0, a) = stops[j];
    final (t1, b) = stops[j + 1];
    final f = (t - t0) / (t1 - t0);
    out.add(((a[0] + (b[0] - a[0]) * f).round(), (a[1] + (b[1] - a[1]) * f).round(), (a[2] + (b[2] - a[2]) * f).round()));
  }
  return out;
}();

(int, int, int) _heatOf(double p) => _heat[(p * 63).round().clamp(0, 63)];
Color _rgba((int, int, int) c, double a) => Color.fromRGBO(c.$1, c.$2, c.$3, a.clamp(0.0, 1.0));

/// The smoothed key display state, advanced once per frame.
class BoardAnim {
  final dp = List<double>.filled(buttonCount, 0), dx = List<double>.filled(buttonCount, 0), dy = List<double>.filled(buttonCount, 0);
  double lastDraw = -1e9;
  bool force = true;

  /// Returns true when something moves (the board must repaint).
  bool step(LiveState live, double now, double dt, {required bool hovering}) {
    final kUp = 1 - math.exp(-dt / 16), kDown = 1 - math.exp(-dt / 110), kXY = 1 - math.exp(-dt / 30);
    var busy = hovering || now - lastDraw > 1000;
    for (final id in keyIds) {
      final target = math.min(1.0, live.pres[id].toDouble());
      final d = dp[id];
      dp[id] = d + (target - d) * (target > d ? kUp : kDown);
      if (dp[id] < 0.002 && target == 0) dp[id] = 0;
      dx[id] += (live.x[id] - dx[id]) * kXY;
      dy[id] += (live.y[id] - dy[id]) * kXY;
      if (dp[id] > 0 || now - live.strikeT[id] < 700 || now - live.releaseT[id] < 500) busy = true;
    }
    for (var i = 0; i < 4; i++) {
      if (live.controls[i] == 1 || now - live.controlT[i] < 400) busy = true;
    }
    return busy;
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

class BoardView extends StatefulWidget {
  final AppController ctl;
  const BoardView(this.ctl, {super.key});

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
    super.dispose();
  }

  void _tick(Duration t) {
    final dt = math.min(100.0, (t - _last).inMicroseconds / 1000);
    _last = t;
    final now = clockMs();
    _updatePlaying(now);
    final busy = anim.step(ctl.live, now, dt, hovering: ctl.hover >= 0 || _pointers.isNotEmpty) || now - ctl.waveT < 1400;
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
    if (h?.key != null && ctl.boardSelect(h!.key!)) return;
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
          cursor: ctl.playable && (ctl.hover >= 0 || ctl.hoverControl >= 0) ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
              child: CustomPaint(size: _size, painter: BoardPainter(ctl, anim, _repaint), isComplex: true, willChange: true),
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
  BoardPainter(this.ctl, this.anim, Listenable repaint) : super(repaint: Listenable.merge([repaint, ctl, ctl.values]));

  static dui.Picture? _static;
  static String _staticSig = '';

  LiveState get live => ctl.live;

  String _signature(Size size) {
    final eq = ctl.eqOn && ctl.params[3]!.params.isNotEmpty;
    final eqSig = eq
        ? [
            for (final id in keyIds) '${ctl.keyParam(id)?.value.toStringAsFixed(3)}:${ctl.lastPeakOf(id).toStringAsFixed(3)}',
            ctl.eqMedian?.toStringAsFixed(3),
            ctl.eqSelected,
          ].join(',')
        : '';
    final setSig = ctl.settingsOn ? '${ctl.current}|${ctl.voices.length}|${ctl.settingsSelected}' : '';
    return '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}|${live.transpose}|${live.transposeFifths}|'
        '${ctl.currentKey?.name}|${ctl.names.name}|$eqSig|$setSig';
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final g = _Geo.of(size);
    final sig = _signature(size);
    if (_static == null || sig != _staticSig) {
      final rec = dui.PictureRecorder();
      _buildStatic(Canvas(rec), size, g);
      _static?.dispose();
      _static = rec.endRecording();
      _staticSig = sig;
    }
    canvas.drawPicture(_static!);
    _dynamic(canvas, g);
  }

  // ---------------------------------------------------------------------------------------------
  // static layer

  void _buildStatic(Canvas c, Size size, _Geo g) {
    final s = g.s, r = keyRadius * s;
    // plate
    final x0 = g.px(plate.x0), y0 = g.py(plate.y1), x1 = g.px(plate.x1), y1 = g.py(plate.y0);
    final rr = RRect.fromLTRBR(x0, y0, x1, y1, Radius.circular(plate.radius * s));
    c.drawRRect(rr, Paint()..shader = dui.Gradient.linear(Offset(0, y0), Offset(0, y1), [_P.plateTop, _P.plateBottom]));
    c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.35)
        ..color = _P.plateEdge,
    );

    // pitch guides: height on the board is pitch; a faint line at every C
    final t = live.transpose;
    for (var midi = 24; midi <= 108; midi += 12) {
      final y = g.py((midi - startNote - t) * mmPerSemitone);
      if (y < y0 + 6 * s || y > y1 - 2 * s) continue;
      dashedLine(
        c,
        Offset(g.px(-76), y),
        Offset(x1 - 2 * s, y),
        Paint()
          ..color = _P.guide
          ..strokeWidth = math.max(1, s * 0.18),
        s * 1.2,
        s * 1.6,
      );
      drawText(
        c,
        'C${midi ~/ 12 - 1}',
        Offset(x1 - 2 * s, y - s * 0.4),
        (s * 2.6).roundToDouble(),
        _P.guideLabel,
        weight: FontWeight.w400,
        align: 1,
        vAlign: 1,
      );
    }

    // keys: by scale membership when a scale is chosen, else natural/accidental like the board
    final key = ctl.currentKey;
    for (final k in boardKeys) {
      final cx = g.px(k.x), cy = g.py(k.y);
      final look = key != null ? _scaleLook[keyRelation(key, keyTpc(k.id, live.transposeFifths))] : null;
      final center = Offset(cx, cy);
      c.drawCircle(
        center,
        r,
        Paint()
          ..shader = dui.Gradient.radial(
            center,
            r,
            [look?.top ?? (k.natural ? const Color(0xFF3A3352) : const Color(0xFF252036)), look?.bottom ?? (k.natural ? _P.natural : _P.accidental)],
            null,
            TileMode.clamp,
            null,
            Offset(cx - r * 0.3, cy - r * 0.35),
            r * 0.1,
          ),
      );
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * (look?.rimW ?? 0.32))
        ..color = look?.rim ?? (k.natural ? _P.naturalRim : _P.accidentalRim);
      if (look != null && look.dash) {
        dashedCircle(c, center, r, rim, s * 1.1, s * 0.9);
      } else {
        c.drawCircle(center, r, rim);
      }
      _label(c, k, cx, cy, r, look?.label);
    }

    if (ctl.eqOn && ctl.params[3]!.params.isNotEmpty && !ctl.settingsOn) _drawEq(c, g, r);
    if (ctl.settingsOn) _drawSettings(c, g, r);

    for (final ctlb in controls) {
      _control(c, g, ctlb, false);
    }
  }

  void _label(Canvas c, KeyInfo k, double cx, double cy, double r, Color? color) {
    final mode = ctl.names;
    if (mode == Names.off) return;
    final n = noteName(k.id, live.transpose, live.transposeFifths);
    final big = (r * 0.78).roundToDouble();
    final col = color ?? (k.natural ? _P.labelNatural : _P.labelAccidental);
    final key = ctl.currentKey;
    if (key != null && (mode == Names.degrees || mode == Names.solfege)) {
      final tpc = keyTpc(k.id, live.transposeFifths);
      final text = mode == Names.degrees ? degreeLabel(key, tpc) : solfege(key, tpc);
      drawText(c, text, Offset(cx, cy + r * 0.04), (r * (text.length > 2 ? 0.62 : 0.74)).roundToDouble(), col);
      return;
    }
    if (mode != Names.octave) {
      drawText(c, n.text, Offset(cx, cy + r * 0.04), big, col);
      return;
    }
    final small = (r * 0.42).roundToDouble();
    final w = textWidth(n.text, big);
    drawText(c, n.text, Offset(cx - small * 0.32, cy + r * 0.02), big, col);
    drawText(c, '${n.octave}', Offset(cx - small * 0.32 + w / 2 + small * 0.42, cy + r * 0.3), small, col, weight: FontWeight.w500);
  }

  // per key: factor as a tint (warm = more sensitive, cool = less) and value, the last press's
  // peak as an arc against the median of the measured keys (green near it, blue low, warm high)
  void _drawEq(Canvas c, _Geo g, double r) {
    final s = g.s;
    final small = math.max(8.0, (r * 0.36).roundToDouble());
    final med = ctl.eqMedian;
    for (final k in boardKeys) {
      final cx = g.px(k.x), cy = g.py(k.y), center = Offset(cx, cy);
      final f = ctl.keyParam(k.id)?.value;
      if (f != null && (math.log(f) / math.ln2).abs() > 0.004) {
        final a = math.min(1.0, (math.log(f) / math.ln2).abs() * 1.6) * 0.5;
        c.drawCircle(center, r * 0.97, Paint()..color = f > 1 ? Color.fromRGBO(255, 138, 101, a) : Color.fromRGBO(122, 167, 255, a));
      }
      if (f != null && (f - 1).abs() > 0.0005) {
        drawText(c, '×${f.toStringAsFixed(2)}', Offset(cx, cy + r * 0.64), small, f > 1 ? const Color(0xFFFFC2AD) : const Color(0xFFBCD2FF));
      }
      final pk = ctl.lastPeakOf(k.id);
      if (pk > 0) {
        final dev = med != null ? pk / med - 1 : 0.0;
        final col = dev.abs() < 0.08 ? const Color(0xFF8FE3A4) : (dev < 0 ? const Color(0xFF7AA7FF) : const Color(0xFFFF8A65));
        final frac = med != null ? math.min(1.0, pk / (2 * med)) : math.min(1.0, pk);
        c.drawArc(
          Rect.fromCircle(center: center, radius: r + s * 1.5),
          -math.pi / 2,
          frac * math.pi * 2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = math.max(2, s * 1.1)
            ..color = col,
        );
        drawText(c, pk >= 1.7 ? 'max' : pk.toStringAsFixed(2), Offset(cx, cy - r * 0.62), small, col);
      }
      if (k.id == ctl.eqSelected) {
        c.drawCircle(
          center,
          r + s * 3.0,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2, s * 0.8)
            ..color = Pal.glacier,
        );
      }
    }
  }

  // what each key does with the Settings button held
  void _drawSettings(Canvas c, _Geo g, double r) {
    final s = g.s;
    final voices = ctl.settingsVoices();
    for (final k in boardKeys) {
      final cx = g.px(k.x), cy = g.py(k.y), center = Offset(cx, cy);
      final f = settingsKeys[k.id];
      if (f == null) {
        c.drawCircle(center, r + s * 0.3, Paint()..color = const Color.fromRGBO(21, 18, 31, 0.78));
        continue;
      }
      final v = f.engine != null ? voices[f.engine] : null;
      final col = f.led != null ? rgb(ledColor(f.led!)) : (f.danger ? const Color(0xFFFF6B6B) : rgb(groupColors[f.group] ?? 0xffffff));
      c.drawCircle(center, r + s * 0.3, Paint()..color = v != null && v.current ? const Color(0xFF3D3420) : const Color(0xFF262036));
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, s * (v != null && v.current ? 1.1 : 0.6))
        ..color = v != null && v.count == 0 ? const Color.fromRGBO(255, 107, 107, 0.6) : col;
      if (f.uncertain) {
        dashedCircle(c, center, r + s * 0.3, rim, s * 1.2, s * 0.8);
      } else {
        c.drawCircle(center, r + s * 0.3, rim);
      }
      if (v != null && v.current) {
        c.drawCircle(center, r * 1.9, Paint()..shader = ring(center, r * 0.8, r * 1.9, [col.withValues(alpha: 0.45), col.withValues(alpha: 0)]));
      }
      if (k.id == ctl.settingsSelected) {
        c.drawCircle(
          center,
          r + s * 2.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2, s * 0.8)
            ..color = Pal.glacier,
        );
      }
      final label = f.short + (f.uncertain ? '?' : '');
      final size = (r * (label.length > 5 ? 0.42 : (label.length > 3 ? 0.5 : 0.6))).roundToDouble();
      drawText(c, label, Offset(cx, cy - (v != null ? r * 0.16 : 0)), size, f.danger ? const Color(0xFFFFB3B3) : const Color(0xFFF3ECDD));
      if (v != null) {
        final sub = v.count == 0 ? 'not here' : (v.current && v.preset.isNotEmpty ? v.preset : (v.count > 1 ? '${v.count} presets' : ''));
        drawText(
          c,
          sub.length > 11 ? '${sub.substring(0, 10)}…' : sub,
          Offset(cx, cy + r * 0.38),
          (r * 0.3).roundToDouble(),
          v.count > 0 ? const Color.fromRGBO(236, 230, 214, 0.75) : const Color.fromRGBO(255, 150, 150, 0.85),
          weight: FontWeight.w500,
        );
      }
    }
    // the button to hold
    final set = controls.firstWhere((b) => b.id == 3);
    c.drawCircle(
      g.at(set.x, set.y),
      8.5 * s,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, s * 0.7)
        ..color = Pal.honey,
    );
    drawText(c, 'hold', Offset(g.px(set.x), g.py(set.y) + 9.5 * s), (s * 3).roundToDouble(), Pal.honey, vAlign: -1);
  }

  void _control(Canvas c, _Geo g, ControlButton b, bool lit, [double glow = 0]) {
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
    c.drawPath(path, Paint()..color = lit ? Color.fromRGBO(244, 210, 122, 0.25 + 0.5 * glow) : _P.control);
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.4)
        ..color = lit ? Pal.honey : _P.controlRim,
    );
    final dotY = cy + (b.shape == ControlShape.up ? r * 0.15 : (b.shape == ControlShape.down ? -r * 0.15 : 0));
    c.drawCircle(Offset(cx, dotY), r * 0.45, Paint()..color = lit ? Pal.honey : const Color(0xFF0F0D17));
  }

  // ---------------------------------------------------------------------------------------------
  // moving layer

  void _dynamic(Canvas c, _Geo g) {
    final s = g.s, r = keyRadius * s;
    final now = clockMs();
    final reduced = ctl.options.reducedMotion;
    final waveAge = now - ctl.waveT;
    for (final k in boardKeys) {
      final id = k.id;
      final cx = g.px(k.x), cy = g.py(k.y), center = Offset(cx, cy);
      final p = anim.dp[id];
      final tx = anim.dx[id].clamp(-1.0, 1.0), ty = anim.dy[id].clamp(-1.0, 1.0);
      final sAge = now - live.strikeT[id], rAge = now - live.releaseT[id];
      var w = 0.0;
      if (waveAge < 1400 && !reduced) {
        final t = (waveAge - ((k.x + 70) / 140) * 700 - ((k.y + 70) / 140) * 120) / 260;
        w = t > 0 && t < 1 ? math.sin(t * math.pi) * 0.55 : 0;
      }
      if (p <= 0 && sAge > 700 && rAge > 500 && w <= 0 && id != ctl.hover) continue;

      if (p > 0) {
        final col = _heatOf(p);
        final gp = Offset(cx + tx * r * 0.4, cy - ty * r * 0.4);
        // bloom outside the key
        final bloom = r * (1.15 + 0.9 * math.sqrt(p));
        c.drawCircle(gp, bloom, Paint()..shader = ring(gp, r * 0.2, bloom, [_rgba(col, 0.38 * math.min(1, p * 2.2)), _rgba(col, 0)]));
        // the key fills with heat from its tilt point
        c.save();
        c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
        final fr = r * (0.35 + 0.95 * math.sqrt(p));
        c.drawRect(
          Rect.fromCircle(center: center, radius: r),
          Paint()..shader = dui.Gradient.radial(gp, fr, [_rgba(_heatOf(math.min(1, p * 1.25)), 0.98), _rgba(col, 0.85), _rgba(col, 0)], [0, 0.6, 1]),
        );
        c.restore();
        c.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, s * 0.45)
            ..color = _rgba(col, 0.95),
        );
      }
      if (w > 0) c.drawCircle(center, r, Paint()..color = Color.fromRGBO(244, 210, 122, w * 0.5));
      // strike: a ring thrown outwards, stronger for harder strikes
      if (sAge < 700 && !reduced) {
        final t = sAge / 700, a = live.strikeA[id];
        final e = 1 - math.pow(1 - t, 3);
        c.drawCircle(
          center,
          r * (1.05 + (0.45 + 0.75 * a) * e),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, s * (0.4 + 1.6 * a) * (1 - t))
            ..color = Color.fromRGBO(255, 240, 215, ((1 - t) * (0.35 + 0.6 * a)).clamp(0, 1)),
        );
      }
      // release: a cool ring drawn back in
      if (rAge < 500 && p < 0.5 && !reduced) {
        final t = rAge / 500;
        c.drawCircle(
          center,
          r * (1.25 - 0.45 * t),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, s * 0.5 * (1 - t))
            ..color = Color.fromRGBO(143, 220, 236, ((1 - t) * 0.55 * live.releaseA[id]).clamp(0, 1)),
        );
      }
      if (p > 0.02 || w > 0.25) {
        _label(c, k, cx, cy, r, p > 0.3 ? const Color.fromRGBO(30, 18, 30, 0.85) : const Color.fromRGBO(255, 248, 235, 0.95));
      }
      // tilt: a needle from the centre
      if (p > 0.02) {
        final end = Offset(cx + tx * r * 0.85, cy - ty * r * 0.85);
        c.drawLine(
          center,
          end,
          Paint()
            ..color = const Color.fromRGBO(21, 18, 31, 0.75)
            ..strokeWidth = math.max(1.5, s * 0.55)
            ..strokeCap = StrokeCap.round,
        );
        c.drawCircle(end, math.max(2, s * 0.75), Paint()..color = const Color(0xFFFFFAF0));
      }
      if (id == ctl.hover) {
        c.drawCircle(
          center,
          r + s * 0.9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, s * 0.3)
            ..color = const Color.fromRGBO(143, 220, 236, 0.8),
        );
      }
    }
    for (final b in controls) {
      final on = live.controls[b.id] == 1;
      final age = now - live.controlT[b.id];
      if (on || age < 400 || b.id == ctl.hoverControl) {
        _control(c, g, b, on, on ? 1 : math.max(0, 1 - age / 400));
        if (b.id == ctl.hoverControl) {
          c.drawCircle(
            g.at(b.x, b.y),
            7.4 * s,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1, s * 0.3)
              ..color = const Color.fromRGBO(143, 220, 236, 0.8),
          );
        }
      }
    }
    // indicator LED: lit while connected
    final led = g.at(ledPosition.x, ledPosition.y);
    c.drawCircle(led, 1.6 * s, Paint()..color = ctl.ledOn ? Pal.ok : const Color(0xFF2C3B31));
    if (ctl.ledOn) {
      c.drawCircle(
        led,
        6 * s,
        Paint()..shader = dui.Gradient.radial(led, 6 * s, [const Color.fromRGBO(124, 242, 154, 0.35), const Color.fromRGBO(124, 242, 154, 0)]),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) => true;
}

// ---------------------------------------------------------------------------------------------
// motion sensor

class MotionView extends StatefulWidget {
  final AppController ctl;
  const MotionView(this.ctl, {super.key});

  @override
  State<MotionView> createState() => _MotionViewState();
}

class _MotionViewState extends State<MotionView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _repaint = Pulse();
  final trail = <Offset>[];
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
      // tilt of 30 degrees reaches the rim
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
    final w = size.width, h = size.height;
    final rr = math.min(w * 0.5, h * 0.62) * 0.78, cx = w / 2, cy = rr + 8;
    final ringP = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color.fromRGBO(160, 150, 200, 0.28);
    for (final f in [1.0, 0.66, 0.33]) {
      g.drawCircle(Offset(cx, cy), rr * f, ringP);
    }
    final cross = Paint()
      ..strokeWidth = 1
      ..color = const Color.fromRGBO(160, 150, 200, 0.14);
    g.drawLine(Offset(cx - rr, cy), Offset(cx + rr, cy), cross);
    g.drawLine(Offset(cx, cy - rr), Offset(cx, cy + rr), cross);
    final b = Offset(cx + st.bx * rr, cy - st.by * rr);
    st.trail.add(b);
    if (st.trail.length > 40) st.trail.removeAt(0);
    if (has) {
      for (var i = 1; i < st.trail.length; i++) {
        final f = i / st.trail.length;
        g.drawLine(
          st.trail[i - 1],
          st.trail[i],
          Paint()
            ..strokeWidth = 2 * f
            ..color = Color.fromRGBO(143, 220, 236, f * 0.5),
        );
      }
    }
    g.drawCircle(
      b,
      rr * 0.15,
      Paint()
        ..shader = dui.Gradient.radial(
          b,
          rr * 0.16,
          [
            has ? const Color(0xFFE6FBFF) : const Color(0xFF4A4560),
            has ? const Color.fromRGBO(143, 220, 236, 0.25) : const Color.fromRGBO(74, 69, 96, 0.2),
          ],
          null,
          TileMode.clamp,
          null,
          b - Offset(rr * 0.04, rr * 0.05),
          0,
        ),
    );
    // rotation bars: x, y, z
    final top = cy + rr + 16, bw = w * 0.62, bh = 5.0, x0 = w - bw - 4;
    for (final (i, ax) in ['x', 'y', 'z'].indexed) {
      final y = top + i * 14;
      g.drawRect(Rect.fromLTWH(x0, y - bh / 2, bw, bh), Paint()..color = const Color.fromRGBO(160, 150, 200, 0.16));
      final gv = [m.gx, m.gy, m.gz][i];
      final v = has ? (gv * 4).clamp(-1.0, 1.0) : 0.0;
      final mid = x0 + bw / 2;
      g.drawRect(Rect.fromLTWH(math.min(mid, mid + v * bw / 2), y - bh / 2, (v * bw / 2).abs(), bh), Paint()..color = Pal.glacier);
      drawText(g, 'rot $ax', Offset(2, y), 11, const Color.fromRGBO(200, 192, 225, 0.7), weight: FontWeight.w400, align: -1);
    }
    drawText(
      g,
      has ? '${m.abs.toStringAsFixed(2)} g' : 'no data',
      Offset(cx, cy + rr * 0.55),
      11,
      has ? const Color.fromRGBO(236, 230, 214, 0.85) : const Color.fromRGBO(160, 150, 200, 0.5),
      weight: FontWeight.w400,
    );
  }

  @override
  bool shouldRepaint(covariant _MotionPainter old) => true;
}
