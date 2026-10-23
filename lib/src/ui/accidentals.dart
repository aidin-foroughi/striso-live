// Quarter-tone accidentals as vector paths (Inter has no such glyphs and font fallback is
// unreliable), in the Stein–Zimmermann system, with the deviation from the nearest quarter tone
// drawn into the glyph as a fraction of a quarter tone:
//
//   sharps   the vertical strokes count quarter tones: one (half-sharp), two (sharp), three
//            (sesquisharp). A pitch 1.68 quarter tones above the letter gets one full stroke and a
//            second at 68% height, growing from the bottom; so "a shade below a sharp" is a sharp
//            whose second stroke is a little short, and "a shade above" adds a short third stroke.
//   flats    the nearest glyph: a reversed flat (half-flat), a flat, or both (sesquiflat). Short of
//            the glyph, its bowl is left open: drawn only as far as the pitch reaches (a flat at
//            70% is 0.3 quarter tones sharp of a flat). Beyond it, a partial bowl grows on the stem
//            toward the next glyph: a half-flat sprouts a right bowl on its way to becoming a flat,
//            a flat sprouts a reversed bowl on its left on its way to the sesquiflat.
//   natural  a partial stroke (sharp side) or a stem with a partial reversed bowl (flat side).
//
// Below qtDrawThreshold (0.1 quarter tone, 5 cents) nothing is added: the readout has the cents.
// Stems are always full height; only bowls and strokes are partial, so a glyph never looks small,
// only unfinished. Behind every partial stroke or bowl the complete glyph is drawn as a ghost at
// 30% so that at key size a small fraction reads as an accidental partly filled, not as a comma.

import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:flutter/painting.dart';
import 'package:striso_core/striso_core.dart';

import '../theme.dart';
import 'paint_util.dart';

// geometry in units of the glyph height h (y down, 0 at the vertical centre)
const _strokeW = 0.085, _strokePitch = 0.22, _barT = 0.15, _barRise = 0.10, _barY = 0.17, _barOver = 0.12;
const _stemW = 0.09, _bowlW = 0.56, _bowlStroke = 0.12, _elementGap = 0.14;
const _ghostAlpha = 0.3;

/// The width of the accidental for [qt] quarter tones at height [h] (0 when nothing is drawn).
double qtAccidentalWidth(double h, double qt) => _plan(qt).fold(0.0, (w, e) => w + e.width) * h;

/// Draws the accidental for [qt] (continuous quarter tones above the natural letter) with its left
/// edge at [left] and vertical centre at [cy], glyph height [h]. Returns the width drawn.
double drawQtAccidental(Canvas c, double left, double cy, double h, double qt, Color color) {
  final plan = _plan(qt);
  var x = left;
  for (final e in plan) {
    e.draw(c, x, cy, h, color);
    x += e.width * h;
  }
  return x - left;
}

// ---------------------------------------------------------------------------------------------
// the plan: which elements make up the glyph

abstract class _Element {
  double get width; // in units of h
  void draw(Canvas c, double x, double cy, double h, Color color);
}

List<_Element> _plan(double qt) {
  if (qt.abs() < qtDrawThreshold) return const [];
  if (qt > 0) {
    // strokes: floor(qt) full ones, then the fraction as a partial stroke
    var n = qt.floor();
    var r = qt - n;
    if (r < qtDrawThreshold) r = 0;
    if (r > 1 - qtDrawThreshold) {
      n++;
      r = 0;
    }
    return [_Sharp(n.clamp(0, 4), r)];
  }
  final a = -qt;
  final m = a.round(); // the nearest flat glyph: 1 half-flat, 2 flat, 3 sesquiflat
  var f = a - m; // positive: beyond the glyph (flatter); negative: short of it
  if (f.abs() < qtDrawThreshold) f = 0;
  switch (m) {
    case 0:
      // a natural a little flat: the beginning of a reversed bowl, no stem yet (the stem comes with
      // the half-flat glyph at half a quarter tone, where this bowl is half drawn: no jump)
      return [_Flat(reversed: true, bowl: f, stem: false)];
    case 1:
      return [_Flat(reversed: true, bowl: f < 0 ? 1 + f : 1, extra: f > 0 ? f : 0)];
    case 2:
      return [_Flat(reversed: false, bowl: f < 0 ? 1 + f : 1, extra: f > 0 ? f : 0)];
    case 3:
      return [_Flat(reversed: true, bowl: 1), _Flat(reversed: false, bowl: f < 0 ? 1 + f : 1)];
    default:
      return [_Flat(reversed: false, bowl: 1), _Flat(reversed: false, bowl: 1)];
  }
}

/// [n] full strokes and one partial stroke of height [partial] (0: none).
class _Sharp implements _Element {
  final int n;
  final double partial;
  const _Sharp(this.n, this.partial);

  int get _strokes => n + (partial > 0 ? 1 : 0);

  @override
  double get width => _strokeW + _strokePitch * math.max(0, _strokes - 1) + 2 * _barOver;

  @override
  void draw(Canvas c, double x, double cy, double h, Color color) {
    if (partial > 0) _paint(c, x, cy, h, color.withValues(alpha: color.a * _ghostAlpha), complete: true);
    _paint(c, x, cy, h, color);
  }

  void _paint(Canvas c, double x, double cy, double h, Color color, {bool complete = false}) {
    final paint = Paint()..color = color;
    final sw = _strokeW * h, pitch = _strokePitch * h;
    final x0 = x + _barOver * h + sw / 2;
    final tops = <double>[]; // top y of each stroke
    for (var k = 0; k < _strokes; k++) {
      final full = complete || k < n;
      final height = full ? 1.0 : partial;
      // engraved sharps lift the right stroke a little above the left
      final lift = _strokes > 1 ? (k / (_strokes - 1) - 0.5) * _barRise : 0.0;
      final bottom = cy + (0.5 - lift) * h;
      final top = bottom - height * h;
      tops.add(top);
      c.drawRect(Rect.fromLTRB(x0 + k * pitch - sw / 2, top, x0 + k * pitch + sw / 2, bottom), paint);
    }
    // the two slanted bars span the strokes that reach them
    for (final by in [-_barY, _barY]) {
      var last = -1;
      for (var k = 0; k < _strokes; k++) {
        if (tops[k] <= cy + (by + _barT / 2) * h) last = k;
      }
      if (last < 0) continue;
      final xa = x0 - _barOver * h - sw / 2, xb = x0 + last * pitch + _barOver * h + sw / 2;
      final rise = _barRise * h * (xb - xa) / (width * h);
      final yc = cy + by * h, t = _barT * h / 2;
      c.drawPath(
        Path()
          ..moveTo(xa, yc + rise / 2 - t)
          ..lineTo(xb, yc - rise / 2 - t)
          ..lineTo(xb, yc - rise / 2 + t)
          ..lineTo(xa, yc + rise / 2 + t)
          ..close(),
        paint,
      );
    }
  }
}

/// A flat (or reversed flat) with its bowl drawn to fraction [bowl], and an [extra] partial bowl on
/// the other side of the stem (0: none).
class _Flat implements _Element {
  final bool reversed, stem;
  final double bowl, extra;
  const _Flat({required this.reversed, required this.bowl, this.extra = 0, this.stem = true});

  // the partial extra bowl's room: its outward reach, at least a third of a bowl
  double get _extraW => extra > 0 ? _bowlW * math.max(0.35, extra) : 0;
  double get _leftW => reversed ? _bowlW : _extraW;
  double get _rightW => reversed ? _extraW : _bowlW;

  @override
  double get width => _elementGap + _leftW + _stemW + _rightW;

  @override
  void draw(Canvas c, double x, double cy, double h, Color color) {
    if (bowl < 0.999 || extra > 0 || !stem) _paint(c, x, cy, h, color.withValues(alpha: color.a * _ghostAlpha), complete: true);
    _paint(c, x, cy, h, color);
  }

  void _paint(Canvas c, double x, double cy, double h, Color color, {bool complete = false}) {
    final paint = Paint()..color = color;
    final sw = _stemW * h;
    final sx = x + (_elementGap / 2 + _leftW) * h;
    if (stem || complete) c.drawRRect(RRect.fromLTRBR(sx, cy - 0.58 * h, sx + sw, cy + 0.5 * h, Radius.circular(sw / 3)), paint);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _bowlStroke * h
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (bowl > 0 || complete) _bowl(c, sx + sw / 2, cy, h, reversed ? -1 : 1, complete ? 1 : bowl, stroke);
    if (extra > 0) _bowl(c, sx + sw / 2, cy, h, reversed ? 1 : -1, complete ? 1 : extra, stroke);
  }

  /// The bowl from the stem's bottom, out to [dir] (1 right, -1 left) and back to the stem at
  /// mid-height, drawn to fraction [k] of its length.
  static void _bowl(Canvas c, double sx, double cy, double h, int dir, double k, Paint p) {
    final w = _bowlW * h * dir;
    final y0 = cy + 0.46 * h; // the stem's bottom (inside the cap)
    final path = Path()
      ..moveTo(sx, y0)
      ..cubicTo(sx + w * 0.62, y0 - 0.06 * h, sx + w * 1.06, y0 - 0.30 * h, sx + w * 0.66, y0 - 0.47 * h)
      ..cubicTo(sx + w * 0.42, y0 - 0.57 * h, sx + w * 0.14, y0 - 0.5 * h, sx, y0 - 0.41 * h);
    if (k >= 0.999) {
      c.drawPath(path, p);
      return;
    }
    for (final m in path.computeMetrics()) {
      c.drawPath(m.extractPath(0, m.length * k.clamp(0.0, 1.0)), p);
    }
  }
}

// ---------------------------------------------------------------------------------------------
// the whole label: letter, accidental, octave digit

/// The parts of a pitch label laid out as one run, relative to the label's centre (0, 0): the
/// letter, the accidental glyph (empty when nothing is drawn) and the octave digit (empty without
/// [small]). The drawing and the overlap test share it.
class QtLabelRun {
  final Rect letter, glyph, digit;
  final double glyphH;
  const QtLabelRun(this.letter, this.glyph, this.digit, this.glyphH);
  double get width => math.max(letter.right, math.max(glyph.right, digit.right)) - letter.left;
}

QtLabelRun qtLabelLayout(QtLabel l, double size, {double? small}) {
  final glyphH = size * 0.95;
  final acc = qtAccidentalWidth(glyphH, l.qt);
  final lw = textWidth(l.letter, size, weight: FontWeight.w500);
  final dw = small == null ? 0.0 : textWidth('${l.octave}', small, weight: FontWeight.w500);
  // gaps: letter to glyph 0.06 em; glyph (or letter) to digit 0.12 em, so a sharp's bars and a
  // flat's bowl never touch the digit
  final gapA = acc > 0 ? 0.06 * size : 0.0, gapD = small == null ? 0.0 : (acc > 0 ? 0.12 : 0.08) * size;
  final total = lw + gapA + acc + gapD + dw;
  final x0 = -total / 2;
  final letter = Rect.fromLTWH(x0, -size / 2, lw, size);
  final glyph = Rect.fromLTWH(x0 + lw + gapA, -0.04 * size - glyphH / 2, acc, acc > 0 ? glyphH : 0);
  final dx = x0 + lw + gapA + acc + gapD;
  final digit = small == null ? Rect.fromLTWH(dx, 0, 0, 0) : Rect.fromLTWH(dx, 0.36 * size - small, dw, small);
  return QtLabelRun(letter, glyph, digit, glyphH);
}

/// The total width of a pitch label: letter at [size], the accidental, and the octave digit at
/// [small] when given.
double qtLabelWidth(QtLabel l, double size, {double? small}) => qtLabelLayout(l, size, small: small).width;

/// The run that fits [maxWidth]: with the octave digit when there is room, else without it (a
/// double flat with a digit is 3.2 em wide, more than a key disc at label size).
QtLabelRun qtLabelFit(QtLabel l, double size, {double? small, double? maxWidth}) {
  final run = qtLabelLayout(l, size, small: small);
  if (small == null || maxWidth == null || run.width <= maxWidth) return run;
  return qtLabelLayout(l, size);
}

/// Draws the pitch label centred at [center]: the letter, its quarter-tone accidental and, with
/// [small], the octave digit baseline-aligned after the run (dropped when the run would pass
/// [maxWidth]).
void drawQtLabel(Canvas c, QtLabel l, Offset center, double size, Color color, {double? small, double? maxWidth}) {
  final run = qtLabelFit(l, size, small: small, maxWidth: maxWidth);
  drawText(c, l.letter, Offset(center.dx + run.letter.left, center.dy), size, color, weight: FontWeight.w500, align: -1);
  if (run.glyph.width > 0) {
    // the glyph sits a little high, like a font's accidental against a capital
    drawQtAccidental(c, center.dx + run.glyph.left, center.dy + run.glyph.center.dy, run.glyphH, l.qt, color);
  }
  if (small != null && run.digit.width > 0) {
    drawText(c, '${l.octave}', Offset(center.dx + run.digit.left, center.dy + run.digit.bottom), small, color, weight: FontWeight.w500, align: -1, vAlign: 1);
  }
}

/// A proof sheet of the accidentals (tests and the design report): quarter tones from -3.5 to
/// +3.5 in steps of [step], drawn at [h] px on a plate.
Future<dui.Image> accidentalSheet({double h = 48, double step = 0.25, double from = -3.5, double to = 3.5}) async {
  final rec = dui.PictureRecorder();
  final count = ((to - from) / step).round() + 1;
  final cell = h * 2.6, rows = 2;
  final w = (count * cell / rows).ceilToDouble() + 40, height = rows * (h * 2.4) + 40;
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w, height), Paint()..color = Pal.bg1);
  final perRow = (count / rows).ceil();
  for (var i = 0; i < count; i++) {
    final qt = from + i * step;
    final row = i ~/ perRow, col = i % perRow;
    final cx = 20 + col * cell + cell / 2, cy = 20 + row * (h * 2.4) + h * 1.1;
    final l = QtLabel(letter: 'C', octave: 4, qt: qt, centsFrom12: 0);
    drawQtLabel(c, l, Offset(cx, cy), h, Pal.t(0.85));
    drawText(c, qt.toStringAsFixed(2), Offset(cx, cy + h * 0.95), math.max(9, h * 0.22), Pal.text3, weight: FontWeight.w500);
  }
  return rec.endRecording().toImage(w.ceil(), height.ceil());
}
