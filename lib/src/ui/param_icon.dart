// A parameter's icon (DESIGN.md 4.2): the engine names one per parameter ("concept" or
// "concept+modifier", awva docs/icons.md), the board sends it (Stcw), and the drawing is awva's
// assets/icons at tool/AWVA_COMMIT (param_icons.g.dart, tool/gen_param_icons.dart): the same
// shapes as the awva app's and plugins'.

import 'package:flutter/widgets.dart';

import 'param_icons.g.dart';

/// whether there is a drawing for this icon (none when the board sent none)
bool hasParamIcon(String icon) => icon.isNotEmpty && paramIconShapes.containsKey(icon.split('+').first);

/// The icon at [size] points: its concept, then (with a modifier) a knockout disc of [background]
/// at (19, 19) r 5.5 on the 24 grid and the modifier's mark. Nothing for an unknown one.
class ParamIcon extends StatelessWidget {
  final String icon;
  final Color color, background;
  final double size;
  const ParamIcon(this.icon, {super.key, required this.color, required this.background, this.size = 14});

  @override
  Widget build(BuildContext context) {
    if (!hasParamIcon(icon)) return SizedBox(width: size, height: size);
    return SizedBox(width: size, height: size, child: CustomPaint(painter: _IconPainter(icon, color, background)));
  }
}

class _IconPainter extends CustomPainter {
  final String icon;
  final Color color, background;
  _IconPainter(this.icon, this.color, this.background);

  static void _draw(Canvas canvas, List<double> s, double k, Paint line, Paint fill) {
    var i = 0;
    while (i < s.length) {
      final kind = s[i].toInt();
      if (kind == 0) {
        final n = s[i + 1].toInt();
        final p = Path()..moveTo(s[i + 2] * k, s[i + 3] * k);
        for (var j = 1; j < n; j++) {
          p.lineTo(s[i + 2 + 2 * j] * k, s[i + 3 + 2 * j] * k);
        }
        canvas.drawPath(p, line);
        i += 2 + 2 * n;
      } else {
        canvas.drawCircle(Offset(s[i + 1] * k, s[i + 2] * k), s[i + 3] * k, kind == 1 ? line : fill);
        i += 4;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    final parts = icon.split('+');
    _draw(canvas, paramIconShapes[parts.first]!, k, line, fill);
    if (parts.length > 1) {
      final mod = paramIconShapes['mod-${parts[1]}'];
      if (mod != null) {
        canvas.drawCircle(Offset(19 * k, 19 * k), 5.5 * k, Paint()..color = background);
        _draw(canvas, mod, k, line, fill);
      }
    }
  }

  @override
  bool shouldRepaint(_IconPainter o) => o.icon != icon || o.color != color || o.background != background;
}

/// A parameter's tooltip lines: its label and hover text (the board's words) when it has them, then
/// [rest]
String paramTip(String label, String hover, String rest) => [if (label.isNotEmpty) label, if (hover.isNotEmpty) hover, rest].join('\n');
