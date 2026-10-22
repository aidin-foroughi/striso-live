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
  // chrome
  static const headerTop = Color(0xFF1B1828), headerBottom = Color(0xFF17141F);
  static const errorBg = Color(0xFF3A1F2A), errorEdge = Color(0xFF5B2C3C), errorText = Color(0xFFFFD9D9);
  static const infoBg = Color(0xFF1D2C35), infoEdge = Color(0xFF2C4A57), infoText = Color(0xFFD5F4FB);
  static const toast = Color(0xFF2A2540);
  static const scrim = Color(0x8015121F);
  static const card = Color(0xF01C1929);
  static const shadow = Color(0x8C05030C);
  static const hover = Color(0x08FFFFFF);
  static const logText = Color(0xFFCFC8E2);
  static const codeText = Color(0xFFE8E2F5);
  static const honeyHover = Color(0xFFFFE09A);
  // knobs and switches
  static const knobCap = Color(0xFF2B2640), knobEdge = Color(0xFF48416A);
  // the key equalizer: warm = more sensitive / above the middle, cool = less / below
  static const eqWarm = Color(0xFFFF8A65), eqWarmText = Color(0xFFFFC2AD), eqUpText = Color(0xFFFFB39D);
  static const eqCool = Color(0xFF7AA7FF), eqCoolText = Color(0xFFBCD2FF), eqDownText = Color(0xFFA9C4FF);
  static const eqEven = Color(0xFF8FE3A4);
  static const meterHot = Color(0xFFFF9654), meterHotter = Color(0xFFFF6270);
  static const dangerKey = Color(0xFFFF6B6B), dangerKeyText = Color(0xFFFFB3B3);
}

/// Spacing (logical pixels).
class Space {
  static const xxs = 2.0, xs = 4.0, s = 6.0, m = 10.0, l = 16.0, xl = 22.0, xxl = 32.0;
}

/// Corner radii.
class Radii {
  static const small = 6.0, big = 14.0, pill = 999.0;
}

/// Type sizes.
class TypeSize {
  static const micro = 10.5, caption = 11.5, small = 12.5, label = 13.0, body = 14.0, title = 15.0, heading = 19.0;
  static const voice = 22.0, keyName = 24.0, invite = 26.0, chord = 46.0, roman = 44.0;
}

/// Durations and curves.
class Timing {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 260);
  static const pulse = Duration(milliseconds: 900);
  static const toast = Duration(milliseconds: 2600);
  static const toastLong = Duration(milliseconds: 6000);
  static const tooltipWait = Duration(milliseconds: 500);
  static const curve = Curves.easeOutCubic;
}

/// Fixed widths of the columns around the board.
class Sizes {
  static const leftColumn = 268.0, rightColumn = 300.0, sideColumn = 360.0, headerHeight = 52.0, tabHeight = 38.0;
  static const knob = 68.0, dial = 48.0, consoleHeight = 260.0;
  static const wide = 1100.0; // narrower windows stack the columns
}

/// The board drawing (board_view.dart): plate, keys, scale looks, heat, rings and overlays.
class BoardPal {
  static const plateTop = Color(0xFF26213A), plateBottom = Color(0xFF1B1829), plateEdge = Color.fromRGBO(244, 210, 122, 0.16);
  static const naturalTop = Color(0xFF3A3352), natural = Color(0xFF302A44), naturalRim = Color.fromRGBO(244, 210, 122, 0.42);
  static const accidentalTop = Color(0xFF252036), accidental = Color(0xFF1E1A2C), accidentalRim = Color.fromRGBO(244, 210, 122, 0.18);
  static const labelNatural = Color.fromRGBO(240, 230, 205, 0.82), labelAccidental = Color.fromRGBO(190, 180, 215, 0.62);
  static const labelOnHeat = Color.fromRGBO(30, 18, 30, 0.85), labelLit = Color.fromRGBO(255, 248, 235, 0.95);
  static const guide = Color.fromRGBO(160, 150, 200, 0.10), guideLabel = Color.fromRGBO(170, 160, 205, 0.45);
  static const control = Color(0xFF2A2540), controlRim = Color.fromRGBO(244, 210, 122, 0.35), controlHole = Color(0xFF0F0D17);
  static const strike = Color(0xFFFFF0D7); // ring thrown out by a strike
  static const needle = Color.fromRGBO(21, 18, 31, 0.75), needleTip = Color(0xFFFFFAF0);
  static const ledOff = Color(0xFF2C3B31);
  static const dim = Color.fromRGBO(21, 18, 31, 0.78); // keys without a settings function
  static const settingsKey = Color(0xFF262036), settingsKeyCurrent = Color(0xFF3D3420);
  static const settingsLabel = Color(0xFFF3ECDD), settingsSub = Color.fromRGBO(236, 230, 214, 0.75), settingsMissing = Color.fromRGBO(255, 150, 150, 0.85);
  static const faintLine = Color.fromRGBO(160, 150, 200, 1); // grids and rings, with an alpha
  static const motionBall = Color(0xFFE6FBFF), motionBallOff = Color(0xFF4A4560), motionText = Color.fromRGBO(200, 192, 225, 1);
  static const morphPad = Color(0xFF18152A), puckEdge = Color(0xFFFFF8EA), puckTrail = Color(0xFFFFF4DC);

  /// Pressure heat: honey -> ember -> rose-white.
  static const heatStops = [(0.0, [244, 210, 122]), (0.45, [255, 150, 84]), (0.75, [255, 98, 110]), (1.0, [255, 226, 236])];
}

/// A key's look for a selected scale: the root clearly, the scale subtly, the rest dimmed.
class KeyLook {
  final Color top, bottom, rim, label;
  final double rimW;
  final bool dash;
  const KeyLook(this.top, this.bottom, this.rim, this.rimW, this.label, [this.dash = false]);

  static const root = KeyLook(Color(0xFF7A6232), Color(0xFF4C3B20), Color.fromRGBO(244, 210, 122, 0.98), 0.62, Color(0xFFFFF0C8));
  static const rootEnharmonic = KeyLook(Color(0xFF4A3F3A), Color(0xFF352C34), Color.fromRGBO(244, 210, 122, 0.6), 0.42, Color.fromRGBO(255, 236, 190, 0.85), true);
  static const inScale = KeyLook(Color(0xFF4A3F5E), Color(0xFF352D4A), Color.fromRGBO(244, 210, 122, 0.5), 0.36, Color.fromRGBO(246, 238, 218, 0.94));
  static const enharmonic = KeyLook(Color(0xFF2D2840), Color(0xFF241F35), Color.fromRGBO(244, 210, 122, 0.3), 0.3, Color.fromRGBO(220, 210, 235, 0.6), true);
  static const out = KeyLook(Color(0xFF201C2E), Color(0xFF1A1726), Color.fromRGBO(160, 150, 200, 0.14), 0.28, Color.fromRGBO(170, 160, 205, 0.42));
}

const String uiFont = 'Bahnschrift';
const List<String> uiFontFallback = ['DIN Alternate', 'Barlow', 'Segoe UI', 'Segoe UI Symbol', 'Helvetica Neue', 'Apple Symbols', 'Arial'];
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
