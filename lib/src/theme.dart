// Design tokens and the small components, from DESIGN.md: a quiet instrument
// panel. Near-black neutral ground, warm off-white type, one accent; colour belongs to the music
// (the engine colours and the pressure heat). Every colour, size, spacing and timing used by the
// widgets and painters lives here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart' show ChordRole, TonalFunction;

// ---------------------------------------------------------------------------------------------
// colour

class Pal {
  // ground
  static const bg0 = Color(0xFF0E0E11); // window
  static const bg1 = Color(0xFF151518); // board plate, drawer, popover body
  static const bg2 = Color(0xFF1D1D22); // hover fill, secondary button, input
  static const bg3 = Color(0xFF26262C); // pressed / selected fill, knob track
  static const hairline = Color(0xFF2B2B33); // input edge, drawer edge, focused rows only
  // type
  static const text1 = Color(0xFFF2EEE6);
  static const text2 = Color(0xFFA5A19A);
  static const text3 = Color(0xFF66635E);
  // meaning
  static const accent = Color(0xFFF0C75E);
  static const accentInk = Color(0xFF1A1507);
  static const ok = Color(0xFF6FD98A);
  static const warn = accent;
  static const error = Color(0xFFFF6B6B);
  static const demo = Color(0xFF7FB2FF);
  static const shadow = Color(0x8C000000); // 0 8 24 rgba(0,0,0,0.55)
  static const scrim = Color(0xB30E0E11);

  /// text1 at the spec's opacity steps: 100 / 68 / 42 / 24.
  static Color t(double a) => text1.withValues(alpha: a);
}

/// The eight engine colours (near-equal lightness), keyed by engine.
const Map<String, Color> engineColors = {
  'strisy': Color(0xFFB9B9C2),
  'va': Color(0xFFFF8A3D),
  'modal': Color(0xFF5CA8FF),
  'bowed': Color(0xFFFF5A5A),
  'wind': Color(0xFF5FD37A),
  'reed': Color(0xFF5FD37A),
  'ep': Color(0xFFB48CFF),
  'epiano': Color(0xFFB48CFF),
  'brass': Color(0xFFE9A23B),
  'trumpet': Color(0xFF2BB7C9), // cyan, L* 68.5: dE >= 31 from modal, 54 from wind, 70 from the accent (also protan/deutan)
};

/// The design's colour of an engine; an engine outside the eight (one from a slot) gets
/// [fallback], its voice key's led colour as the board reports it (0xRRGGBB), else text2.
Color engineColor(String engine, [int? fallback]) => engineColors[engine] ?? (fallback != null ? Color(0xFF000000 | fallback) : Pal.text2);

/// The board: plate, keys, heat ramp, rings and overlays.
class BoardPal {
  static const plate = Pal.bg1;
  static const natural = Color(0xFF222227), accidental = Color(0xFF19191D);
  static const strike = Color(0xFFFFF1E6);
  static const tiltDot = Color(0xFFFFFAF0);
  static const ledOff = Pal.text3;

  /// Pressure heat, p = 0..1 (sRGB interpolation).
  static const heatStops = [
    (0.0, [0xF0, 0xC7, 0x5E]),
    (0.5, [0xFF, 0x8A, 0x4C]),
    (0.85, [0xFF, 0x5C, 0x6C]),
    (1.0, [0xFF, 0xF1, 0xF3]),
  ];
  static const heatMid = Color(0xFFFF8A4C); // warm in the key equalizer
}

// Tonal colouring (rims only, DESIGN.md 5: scale information never fills). Three families on the
// axes dichromats keep, lightness and blue–yellow: tonic honey (the accent), subdominant blue,
// dominant rose. Checked with Machado's protanopia and deuteranopia matrices: the three functions
// stay 36+ CIELAB ΔE apart, the seven degrees at least 11 (the degree numbers are the second cue),
// the five chord roles at least 22.
const Map<TonalFunction, Color> functionColors = {
  TonalFunction.tonic: Pal.accent,
  TonalFunction.subdominant: Color(0xFF6FA0E6),
  TonalFunction.dominant: Color(0xFFE0708C),
};

/// Degrees 1..7: tonic family (1, 3, 6) in honey, sand and olive; subdominant (2, 4) in blue and
/// aqua; dominant (5, 7) in rose and mauve.
const List<Color> degreeColors = [
  Pal.accent,
  Color(0xFF6FA0E6),
  Color(0xFFE8D9B4),
  Color(0xFF8ED6E3),
  Color(0xFFE0708C),
  Color(0xFFA3955A),
  Color(0xFFC58AC9),
];

/// Chord tones: root honey, third rose, fifth blue, seventh aqua, extensions olive.
const Map<ChordRole, Color> chordColors = {
  ChordRole.root: Pal.accent,
  ChordRole.third: Color(0xFFE0708C),
  ChordRole.fifth: Color(0xFF6FA0E6),
  ChordRole.seventh: Color(0xFF8ED6E3),
  ChordRole.extension: Color(0xFFA3955A),
};

const functionLetters = {TonalFunction.tonic: 'T', TonalFunction.subdominant: 'S', TonalFunction.dominant: 'D'};
const chordRoleLetters = {ChordRole.root: 'R', ChordRole.third: '3', ChordRole.fifth: '5', ChordRole.seventh: '7', ChordRole.extension: '+'};

// ---------------------------------------------------------------------------------------------
// type

const String uiFont = 'Inter';
const List<String> uiFontFallback = ['Segoe UI', 'Helvetica Neue', 'Segoe UI Symbol', 'Apple Symbols', 'Arial'];
const String serifFont = 'Georgia';
const List<String> serifFallback = ['Times New Roman', 'Times', 'Segoe UI Symbol', 'Apple Symbols'];
const String monoFont = 'Cascadia Mono';
const List<String> monoFallback = ['Menlo', 'Consolas', 'Courier New'];

class TypeSize {
  static const micro = 11.0, small = 12.0, body = 13.0, title = 15.0, sound = 20.0, chord = 36.0, roman = 32.0, stage = 48.0;
}

TextStyle ui(double size, {Color color = Pal.text1, FontWeight weight = FontWeight.w400, double? height, double? spacing}) => TextStyle(
  fontFamily: uiFont,
  fontFamilyFallback: uiFontFallback,
  fontSize: size,
  color: color,
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
  height: height ?? _lineHeight(size),
  letterSpacing: spacing,
  fontFeatures: const [FontFeature.tabularFigures()],
);

double? _lineHeight(double size) => switch (size) {
  TypeSize.micro => 14 / 11,
  TypeSize.small => 16 / 12,
  TypeSize.body => 18 / 13,
  TypeSize.title => 20 / 15,
  TypeSize.sound => 24 / 20,
  TypeSize.chord => 40 / 36,
  TypeSize.stage => 52 / 48,
  _ => null,
};

/// Group names and column labels: 11/14, 500, uppercase, +0.08em.
TextStyle microStyle({Color color = Pal.text3}) => ui(TypeSize.micro, color: color, weight: FontWeight.w500, spacing: 0.88);

TextStyle serif(double size, {Color color = Pal.text1}) =>
    TextStyle(fontFamily: serifFont, fontFamilyFallback: serifFallback, fontSize: size, color: color, height: 1.1);

TextStyle mono(double size, {Color color = Pal.text2}) =>
    TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

// ---------------------------------------------------------------------------------------------
// spacing, radii, sizes, motion

class Space {
  static const xxs = 2.0, xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0, xxxl = 48.0;
  static const gutter = 16.0, column = 24.0, control = 8.0;
}

class Radii {
  static const small = 4.0, popover = 8.0, dialog = 12.0, full = 999.0;
}

class Sizes {
  static const header = 48.0, toolbar = 36.0, row = 28.0, control = 28.0, stageStrip = 24.0;
  static const left = 220.0, leftNarrow = 180.0, right = 260.0, rightNarrow = 220.0, fxColumn = 300.0, setupRight = 360.0;
  static const knobHero = 56.0, knob = 44.0, knobStrip = 44.0, knobInline = 36.0;
  static const harmony = 96.0, console = 240.0, morph = 260.0, morphPad = 220.0, motion = 120.0;
  static const minWidth = 1000.0, minHeight = 700.0;
}

class Timing {
  static const quick = Duration(milliseconds: 120);
  static const tab = Duration(milliseconds: 180);
  static const open = Duration(milliseconds: 240);
  static const stage = Duration(milliseconds: 320);
  static const strike = Duration(milliseconds: 450);
  static const toastIn = Duration(milliseconds: 180);
  static const toast = Duration(milliseconds: 2600);
  static const pulse = Duration(milliseconds: 1000);
  static const sweep = Duration(milliseconds: 600);
  static const reduced = Duration(milliseconds: 80);
  static const tooltipWait = Duration(milliseconds: 500);
  static const curveOut = Curves.easeOut;
  static const curveTab = Curves.easeOutCubic;
  static const curveOpen = Curves.easeInOutCubic;
}

const elevation = [BoxShadow(color: Pal.shadow, blurRadius: 24, offset: Offset(0, 8))];

ThemeData strisoTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: uiFont,
    fontFamilyFallback: uiFontFallback,
    scaffoldBackgroundColor: Pal.bg0,
    colorScheme: const ColorScheme.dark(
      primary: Pal.accent,
      onPrimary: Pal.accentInk,
      secondary: Pal.accent,
      surface: Pal.bg1,
      onSurface: Pal.text1,
      error: Pal.error,
      outline: Pal.hairline,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Pal.bg2,
    focusColor: Pal.accent.withValues(alpha: 0.2),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Pal.text1, displayColor: Pal.text1, fontFamily: uiFont),
    tooltipTheme: TooltipThemeData(
      waitDuration: Timing.tooltipWait,
      decoration: BoxDecoration(color: Pal.bg1, borderRadius: BorderRadius.circular(Radii.popover), boxShadow: elevation),
      textStyle: ui(TypeSize.small),
      padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs + 2),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: Pal.accent,
      inactiveTrackColor: Pal.bg3,
      thumbColor: Pal.text1,
      overlayColor: Pal.accent.withValues(alpha: 0.12),
      thumbShape: const _RingThumb(),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      showValueIndicator: ShowValueIndicator.never,
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Pal.bg1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
    ),
    scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(Pal.t(0.18)), thickness: const WidgetStatePropertyAll(6)),
    textSelectionTheme: TextSelectionThemeData(cursorColor: Pal.accent, selectionColor: Pal.accent.withValues(alpha: 0.3)),
    popupMenuTheme: PopupMenuThemeData(
      color: Pal.bg1,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.popover)),
      textStyle: ui(TypeSize.body),
    ),
  );
}

/// Slider thumb: 14 px text1 with a 2 px bg0 ring.
class _RingThumb extends SliderComponentShape {
  const _RingThumb();
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(18, 18);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final c = context.canvas;
    c.drawCircle(center, 9, Paint()..color = Pal.bg0);
    c.drawCircle(center, 7, Paint()..color = enableAnimation.value > 0.5 ? Pal.text1 : Pal.text3);
  }
}

// ---------------------------------------------------------------------------------------------
// components: buttons, icon buttons, segmented control, select, toggle, labels

enum BtnKind { primary, secondary, ghost, danger }

/// 28 px, radius 4, body 500. Disabled: 35% opacity, the reason in the tooltip. In the Tab order
/// (Enter or Space presses it) with the focus ring: 1 px accent, 2 px outside.
class Btn extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool pressed;
  final String? tooltip;
  final IconData? icon;
  const Btn(this.label, {super.key, this.onPressed, this.kind = BtnKind.secondary, this.pressed = false, this.tooltip, this.icon});

  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> {
  bool _hover = false, _focus = false;

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.space && e.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    widget.onPressed?.call();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final k = widget.kind;
    final selected = widget.pressed;
    final (Color bg, Color fg) = switch (k) {
      BtnKind.primary => (Pal.accent, Pal.accentInk),
      BtnKind.secondary => (selected ? Pal.bg3 : (_hover && enabled ? Pal.bg3 : Pal.bg2), Pal.text1),
      BtnKind.ghost => (
        selected ? Pal.bg3 : (_hover && enabled ? Pal.bg2 : Colors.transparent),
        selected || (_hover && enabled) ? Pal.text1 : Pal.text2,
      ),
      BtnKind.danger => (_hover && enabled ? Pal.bg2 : Colors.transparent, Pal.error),
    };
    Widget w = Focus(
      canRequestFocus: enabled,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focus = f),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedOpacity(
            duration: Timing.quick,
            opacity: enabled ? 1 : 0.35,
            child: AnimatedContainer(
              duration: Timing.quick,
              height: Sizes.control,
              padding: EdgeInsets.symmetric(horizontal: widget.label.isEmpty ? 0 : Space.m),
              constraints: BoxConstraints(minWidth: widget.label.isEmpty ? Sizes.control : 0),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.small)),
              foregroundDecoration: _focus ? focusRing : null,
              // the label is one text (it ellipsizes when squeezed, and needs no bounded width:
              // a toolbar that scrolls, a FittedBox); with an icon, a row. Align with a
              // widthFactor: as wide as the label, the 28 px tall, centred
              child: Align(
                widthFactor: 1,
                child: widget.label.isEmpty
                    ? Icon(widget.icon, size: 16, color: fg)
                    : widget.icon == null
                    ? Text(
                        widget.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: ui(TypeSize.body, color: fg, weight: FontWeight.w500),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(widget.icon, size: 16, color: fg),
                          const SizedBox(width: Space.xs + 2),
                          Text(
                            widget.label,
                            maxLines: 1,
                            softWrap: false,
                            style: ui(TypeSize.body, color: fg, weight: FontWeight.w500),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) w = Tooltip(message: widget.tooltip!, child: w);
    return Semantics(button: true, enabled: enabled, label: widget.label.isEmpty ? widget.tooltip : widget.label, child: w);
  }
}

/// The focus ring (DESIGN.md: 1 px accent, 2 px outside), drawn over a control's box.
final focusRing = _FocusRing();

class _FocusRing extends Decoration {
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _FocusRingPainter();
}

class _FocusRingPainter extends BoxPainter {
  @override
  void paint(Canvas c, Offset o, ImageConfiguration cfg) {
    final r = (o & (cfg.size ?? Size.zero)).inflate(2);
    c.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(Radii.small + 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Pal.accent,
    );
  }
}

/// A 28x28 ghost icon button, always with a tooltip.
class IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool pressed;
  const IconBtn(this.icon, {super.key, required this.tooltip, this.onPressed, this.pressed = false});
  @override
  Widget build(BuildContext context) => Btn('', icon: icon, kind: BtnKind.ghost, tooltip: tooltip, onPressed: onPressed, pressed: pressed);
}

/// Ghost segments in one row; the selected one bg3 / text1; no outer border.
class Seg<T> extends StatelessWidget {
  final List<(T, String, String?)> items; // value, label, tooltip
  final T value;
  final ValueChanged<T> onChanged;
  final Map<T, Key>? keys;
  const Seg({super.key, required this.items, required this.value, required this.onChanged, this.keys});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (v, label, tip) in items)
          Btn(label, key: keys?[v], kind: BtnKind.ghost, pressed: v == value, tooltip: tip, onPressed: () => onChanged(v)),
      ],
    );
  }
}

/// A select: bg2, 28 px, chevron text3, the menu as a popover.
class SmallSelect<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T>? onChanged;
  final double? width;
  final String? tooltip;
  const SmallSelect({super.key, required this.value, required this.items, required this.onChanged, this.width, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final label = items.where((i) => i.$1 == value).map((i) => i.$2).firstOrNull ?? '';
    Widget w = PopupMenuButton<T>(
      enabled: onChanged != null,
      tooltip: tooltip ?? '',
      initialValue: value,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 120, maxHeight: 520),
      onSelected: (v) => onChanged?.call(v),
      itemBuilder: (context) => [
        for (final (v, l) in items)
          PopupMenuItem<T>(
            value: v,
            height: Sizes.row,
            child: Text(l, style: ui(TypeSize.body, color: v == value ? Pal.accent : Pal.text1)),
          ),
      ],
      child: Opacity(
        opacity: onChanged == null ? 0.35 : 1,
        child: SelectFace(label: label, width: width),
      ),
    );
    return w;
  }
}

/// The closed look of a select: bg2, bg3 under the pointer (as a secondary button).
class SelectFace extends StatefulWidget {
  final String label;
  final double? width;
  const SelectFace({super.key, required this.label, this.width});
  @override
  State<SelectFace> createState() => _SelectFaceState();
}

class _SelectFaceState extends State<SelectFace> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final width = widget.width, label = widget.label;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: Timing.quick,
        width: width,
        height: Sizes.control,
        padding: const EdgeInsets.only(left: Space.s + 2, right: Space.xs + 2),
        decoration: BoxDecoration(color: _hover ? Pal.bg3 : Pal.bg2, borderRadius: BorderRadius.circular(Radii.small)),
        child: Row(
          mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.body)),
            ),
            const SizedBox(width: Space.xs),
            const Icon(Icons.expand_more, size: 16, color: Pal.text3),
          ],
        ),
      ),
    );
  }
}

/// A 28x16 pill: bg3 off, accent on, a 12 px white knob; the label at the right. In the Tab
/// order (Enter or Space switches it).
class Toggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? label;
  const Toggle({super.key, required this.value, required this.onChanged, this.label});
  @override
  State<Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<Toggle> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final value = widget.value, label = widget.label;
    return Focus(
      onFocusChange: (f) => setState(() => _focus = f),
      onKeyEvent: (n, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (k != LogicalKeyboardKey.enter && k != LogicalKeyboardKey.space && k != LogicalKeyboardKey.numpadEnter) return KeyEventResult.ignored;
        widget.onChanged(!value);
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onChanged(!value),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: Timing.quick,
                width: 28,
                height: 16,
                padding: const EdgeInsets.all(2),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                decoration: BoxDecoration(color: value ? Pal.accent : Pal.bg3, borderRadius: BorderRadius.circular(Radii.full)),
                foregroundDecoration: _focus ? focusRing : null,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: Space.s),
                Text(label, maxLines: 1, softWrap: false, style: ui(TypeSize.body, color: Pal.text2)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A micro label: group names, column labels.
class Micro extends StatelessWidget {
  final String text;
  final Color color;
  const Micro(this.text, {super.key, this.color = Pal.text3});
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: microStyle(color: color));
}

/// One sentence in body text2 at the top of an area: an empty state.
class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text, style: ui(TypeSize.body, color: Pal.text2));
}

/// A filled circle of [size] in [color].
class Pip extends StatelessWidget {
  final Color color;
  final double size;
  final bool hollow;
  const Pip(this.color, {super.key, this.size = 6, this.hollow = false});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: hollow ? null : color,
      border: hollow ? Border.all(color: color) : null,
    ),
  );
}

Color rgb(int c, [double opacity = 1]) => Color.fromRGBO((c >> 16) & 255, (c >> 8) & 255, c & 255, opacity);
