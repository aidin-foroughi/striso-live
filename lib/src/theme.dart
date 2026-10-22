// The faceplate look of the web app (tools/app/css/app.css): panels meet at 1px seams; honey
// marks the voice, glacier the effects and motion, ember is pressure heat. Bahnschrift (the DIN
// of Windows) does the engraving; macOS falls back to DIN Alternate.

import 'package:flutter/material.dart';

class Pal {
  static const ink = Color(0xFF15121F);
  static const panel = Color(0xFF1C1929);
  static const panel2 = Color(0xFF231F35);
  static const seam = Color(0xFF2F2A45);
  static const line = Color(0xFF3A3454);
  static const text = Color(0xFFECE6D6);
  static const muted = Color(0xFF9D95B5);
  static const faint = Color(0xFF6C6588);
  static const honey = Color(0xFFF4D27A);
  static const honeyDim = Color(0x29F4D27A);
  static const ember = Color(0xFFFF8A65);
  static const glacier = Color(0xFF8FDCEC);
  static const glacierDim = Color(0x248FDCEC);
  static const danger = Color(0xFFFF7A7A);
  static const ok = Color(0xFF7CF29A);
  static const onHoney = Color(0xFF1B1606);
  static const lilac = Color(0xFFB9A3FF);
}

const String uiFont = 'Bahnschrift';
const List<String> uiFontFallback = ['DIN Alternate', 'Barlow', 'Segoe UI', 'Helvetica Neue', 'Arial'];
const String serifFont = 'Cambria';
const List<String> serifFallback = ['Georgia', 'Times New Roman', 'Times'];
const String monoFont = 'Cascadia Mono';
const List<String> monoFallback = ['Consolas', 'Menlo', 'Courier New'];

TextStyle ui(double size, {Color color = Pal.text, FontWeight weight = FontWeight.w400, double? height}) => TextStyle(
  fontFamily: uiFont,
  fontFamilyFallback: uiFontFallback,
  fontSize: size,
  color: color,
  fontWeight: weight,
  height: height,
  fontFeatures: const [FontFeature.tabularFigures()],
);

TextStyle serif(double size, {Color color = Pal.text}) =>
    TextStyle(fontFamily: serifFont, fontFamilyFallback: serifFallback, fontSize: size, color: color, height: 1.05);

TextStyle mono(double size, {Color color = Pal.muted}) =>
    TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

ThemeData strisoTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: uiFont,
    fontFamilyFallback: uiFontFallback,
    scaffoldBackgroundColor: Pal.ink,
    colorScheme: const ColorScheme.dark(
      primary: Pal.honey,
      onPrimary: Pal.onHoney,
      secondary: Pal.glacier,
      surface: Pal.panel,
      onSurface: Pal.text,
      error: Pal.danger,
      outline: Pal.line,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: const Color(0x08FFFFFF),
    focusColor: const Color(0x228FDCEC),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Pal.text, displayColor: Pal.text, fontFamily: uiFont),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2540),
        border: Border.all(color: Pal.line),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: ui(12.5),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      inactiveTrackColor: Pal.line,
      showValueIndicator: ShowValueIndicator.never,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Pal.honey : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Pal.onHoney),
      side: const BorderSide(color: Pal.muted),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Pal.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Pal.line),
      ),
    ),
    scrollbarTheme: const ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(Pal.line)),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: Pal.glacier, selectionColor: Color(0x558FDCEC)),
  );
}

// ---------------------------------------------------------------------------------------------
// small building blocks: buttons, segmented control, area header

enum BtnKind { normal, primary, quiet }

class Btn extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool small;
  final bool pressed;
  final String? tooltip;
  final double? fontSize;
  final EdgeInsets? padding;
  const Btn(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = BtnKind.normal,
    this.small = false,
    this.pressed = false,
    this.tooltip,
    this.fontSize,
    this.padding,
  });

  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final primary = widget.kind == BtnKind.primary || widget.pressed;
    final quiet = widget.kind == BtnKind.quiet && !widget.pressed;
    Color bg = primary ? (_hover && enabled ? const Color(0xFFFFE09A) : Pal.honey) : (quiet ? Colors.transparent : Pal.panel2);
    Color border = primary ? Pal.honey : (quiet ? (_hover && enabled ? Pal.line : Colors.transparent) : (_hover && enabled ? Pal.muted : Pal.line));
    Color fg = primary ? Pal.onHoney : (quiet ? (_hover && enabled ? Pal.text : Pal.muted) : Pal.text);
    final size = widget.fontSize ?? (widget.small ? 12.5 : 14);
    final pad =
        widget.padding ??
        (widget.small ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3) : const EdgeInsets.symmetric(horizontal: 12, vertical: 6));
    Widget w = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Transform.translate(
            offset: Offset(0, _down ? 1 : 0),
            child: Container(
              padding: pad,
              decoration: BoxDecoration(
                color: bg,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.label,
                style: ui(size, color: fg, weight: primary ? FontWeight.w600 : FontWeight.w400, height: 1.2),
                maxLines: 1,
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) w = Tooltip(message: widget.tooltip!, child: w);
    return Semantics(button: true, enabled: enabled, label: widget.label, child: w);
  }
}

class Seg<T> extends StatelessWidget {
  final List<(T, String, String?)> items; // value, label, tooltip
  final T value;
  final ValueChanged<T> onChanged;
  const Seg({super.key, required this.items, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Pal.line),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, (v, label, tip)) in items.indexed) ...[
              if (i > 0) Container(width: 1, height: 22, color: Pal.line),
              _SegButton(label: label, tooltip: tip, on: v == value, onTap: () => onChanged(v)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SegButton extends StatelessWidget {
  final String label;
  final String? tooltip;
  final bool on;
  final VoidCallback onTap;
  const _SegButton({required this.label, required this.on, required this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    Widget w = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          color: on ? Pal.panel2 : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Text(label, style: ui(12.5, color: on ? Pal.text : Pal.muted)),
        ),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return Semantics(button: true, selected: on, child: w);
  }
}

class AreaHead extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final String? sub;
  const AreaHead(this.title, {super.key, this.children = const [], this.sub});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Text(title, style: ui(15, weight: FontWeight.w600)),
          if (sub != null) Text(sub!, style: ui(12.5, color: Pal.faint)),
          ...children,
        ],
      ),
    );
  }
}

/// A row header with a title on the left and controls pushed to the right.
class AreaHeadRow extends StatelessWidget {
  final String title;
  final List<Widget> left, right;
  const AreaHeadRow(this.title, {super.key, this.left = const [], this.right = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Text(title, style: ui(15, weight: FontWeight.w600)),
          for (final w in left) Padding(padding: const EdgeInsets.only(left: 10), child: w),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [for (final w in right) FittedBox(fit: BoxFit.scaleDown, child: w)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CheckLabel extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const CheckLabel(this.label, {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: 4),
            Text(label, style: ui(13, color: Pal.muted)),
          ],
        ),
      ),
    );
  }
}

/// A compact dropdown in the faceplate style.
class SmallSelect<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T>? onChanged;
  final double? width;
  const SmallSelect({super.key, required this.value, required this.items, required this.onChanged, this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: Pal.ink,
        border: Border.all(color: Pal.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: width != null,
          dropdownColor: Pal.panel2,
          iconSize: 16,
          iconEnabledColor: Pal.muted,
          style: ui(12.5),
          items: [
            for (final (v, label) in items)
              DropdownMenuItem(
                value: v,
                child: Text(label, style: ui(12.5)),
              ),
          ],
          onChanged: onChanged == null ? null : (v) => v == null ? null : onChanged!(v),
        ),
      ),
    );
  }
}

Color rgb(int c, [double opacity = 1]) => Color.fromRGBO((c >> 16) & 255, (c >> 8) & 255, c & 255, opacity);
