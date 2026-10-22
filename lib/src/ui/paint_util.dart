// Canvas helpers the web app had from the 2D canvas: dashed strokes, text at a point.

import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:flutter/painting.dart';

import '../theme.dart';

/// A dashed circle (dash and gap as arc lengths).
void dashedCircle(Canvas c, Offset center, double r, Paint p, double dash, double gap) {
  if (r <= 0) return;
  final circ = 2 * math.pi * r;
  final n = math.max(1, (circ / (dash + gap)).floor());
  final step = 2 * math.pi / n, sweep = step * dash / (dash + gap);
  final rect = Rect.fromCircle(center: center, radius: r);
  for (var i = 0; i < n; i++) {
    c.drawArc(rect, i * step, sweep, false, p);
  }
}

void dashedLine(Canvas c, Offset a, Offset b, Paint p, double dash, double gap) {
  final d = b - a;
  final len = d.distance;
  if (len <= 0) return;
  final u = d / len;
  for (var t = 0.0; t < len; t += dash + gap) {
    c.drawLine(a + u * t, a + u * math.min(len, t + dash), p);
  }
}

final _textCache = <String, TextPainter>{};

/// Draws text with its anchor at [at]: align -1 left, 0 centre, 1 right; vAlign -1 top,
/// 0 middle, 1 bottom (alphabetic baselines approximated by the box).
void drawText(
  Canvas c,
  String text,
  Offset at,
  double size,
  Color color, {
  FontWeight weight = FontWeight.w600,
  int align = 0,
  int vAlign = 0,
  String? family,
}) {
  if (text.isEmpty || size <= 0) return;
  final key = '$text|${size.toStringAsFixed(1)}|${color.toARGB32()}|${weight.value}|${family ?? ''}';
  var tp = _textCache[key];
  if (tp == null) {
    tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: family ?? uiFont,
          fontFamilyFallback: uiFontFallback,
          fontSize: size,
          color: color,
          fontWeight: weight,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (_textCache.length > 3000) _textCache.clear();
    _textCache[key] = tp;
  }
  final dx = align < 0 ? 0.0 : (align == 0 ? -tp.width / 2 : -tp.width);
  final dy = vAlign < 0 ? 0.0 : (vAlign == 0 ? -tp.height / 2 : -tp.height);
  tp.paint(c, at + Offset(dx, dy));
}

double textWidth(String text, double size, {FontWeight weight = FontWeight.w600}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: uiFont, fontFamilyFallback: uiFontFallback, fontSize: size, fontWeight: weight),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.width;
}

/// A radial gradient from an inner radius (transparent inside it follows the first colour).
dui.Gradient ring(Offset c, double r0, double r1, List<Color> colors, [List<double>? stops]) {
  final f = r1 <= 0 ? 0.0 : (r0 / r1).clamp(0.0, 1.0);
  final s = stops ?? [for (var i = 0; i < colors.length; i++) colors.length == 1 ? 1.0 : f + (1 - f) * i / (colors.length - 1)];
  return dui.Gradient.radial(c, math.max(0.01, r1), colors, s);
}
