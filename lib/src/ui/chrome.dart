// Shared chrome (DESIGN.md 4.5, 4.6): brand mark, status dot, the persistent problem strip,
// toasts, dialogs, the shortcut overlay and the inline invite on the board.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'build_picker.dart';

class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 20});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _BrandPainter());
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 32;
    void dot(double x, double y, double r, Color col) => c.drawCircle(Offset(x * k, y * k), r * k, Paint()..color = col);
    dot(11, 12, 5, Pal.accent);
    dot(21, 9, 4, Pal.accent.withValues(alpha: 0.55));
    dot(21, 21, 5, BoardPal.heatMid);
    dot(11, 24, 3.5, Pal.accent.withValues(alpha: 0.4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// The connection dot: hollow text3 when disconnected, ok when connected, accent pulsing while
/// looking or connecting, error when lost, demo blue in the demo.
class StatusDot extends StatefulWidget {
  final Dot dot;
  final bool lost;
  const StatusDot(this.dot, {super.key, this.lost = false});
  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: Timing.pulse);

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
    final col = widget.lost
        ? Pal.error
        : switch (widget.dot) {
            Dot.on => Pal.ok,
            Dot.demo => Pal.demo,
            Dot.busy => Pal.accent,
            Dot.off => Pal.text3,
          };
    return AnimatedBuilder(
      animation: _a,
      builder: (_, _) => Opacity(
        opacity: 1 - 0.6 * _a.value,
        child: Pip(col, size: 8, hollow: widget.dot == Dot.off && !widget.lost),
      ),
    );
  }
}

/// Persistent problems: a 32 px strip under the header, bg2, a dot, the text and a close.
class BannerBar extends StatelessWidget {
  final AppController ctl;
  const BannerBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final p = ctl.problem;
        final b = ctl.banner;
        return AnimatedSize(
          duration: Timing.open,
          curve: Timing.curveOpen,
          child: p != null
              ? Container(
                  key: const Key('problem'),
                  constraints: const BoxConstraints(minHeight: 32),
                  color: Pal.bg2,
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs + 2),
                  child: Row(
                    children: [
                      const Pip(Pal.error, size: 6),
                      const SizedBox(width: Space.s),
                      Expanded(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: Space.m,
                          runSpacing: Space.xs,
                          children: [
                            Text(p.title, key: const Key('problem-title'), style: ui(TypeSize.body, weight: FontWeight.w500)),
                            if (p.detail.isNotEmpty) SelectableText(p.detail, style: ui(TypeSize.body, color: Pal.text2)),
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.m),
                      FixButtons(ctl, p.actions, lead: false),
                    ],
                  ),
                )
              : b == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  key: const Key('banner'),
                  constraints: const BoxConstraints(minHeight: 32),
                  color: Pal.bg2,
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs + 2),
                  child: Row(
                    children: [
                      Pip(b.info ? Pal.text2 : Pal.error, size: 6),
                      const SizedBox(width: Space.s),
                      Expanded(child: SelectableText(b.text, style: ui(TypeSize.body))),
                      IconBtn(Icons.close, tooltip: 'Dismiss', onPressed: ctl.hideBanner),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// Toasts: bottom right, bg1 with a shadow, a leading dot, at most four; a click dismisses, an
/// action button when there is one.
class ToastLayer extends StatelessWidget {
  final AppController ctl;
  const ToastLayer(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ToastMsg>>(
      valueListenable: ctl.toasts,
      builder: (context, list, _) => Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final t in list)
                Padding(
                  key: ValueKey(t.id),
                  padding: const EdgeInsets.only(top: Space.s),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: Timing.toastIn,
                    curve: Timing.curveOut,
                    builder: (_, v, child) => Opacity(
                      opacity: v,
                      child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
                    ),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => ctl.dismissToast(t.id),
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 420),
                          padding: const EdgeInsets.all(Space.m),
                          decoration: BoxDecoration(color: Pal.bg1, borderRadius: BorderRadius.circular(Radii.popover), boxShadow: elevation),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Pip(t.kind == 'error' ? Pal.error : (t.kind == 'warn' ? Pal.accent : Pal.ok)),
                              const SizedBox(width: Space.s),
                              Flexible(child: Text(t.text, style: ui(TypeSize.body))),
                              if (t.action != null) ...[
                                const SizedBox(width: Space.s),
                                Btn(
                                  t.action!,
                                  key: Key('toast-${t.action}'),
                                  kind: BtnKind.ghost,
                                  onPressed: () {
                                    t.onAction?.call();
                                    ctl.dismissToast(t.id);
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On the board while disconnected (no card): title, one sentence, Connect Striso and Play Virtual
/// Striso (the two modes).
class InviteCard extends StatelessWidget {
  final AppController ctl;
  const InviteCard(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final inv = ctl.invite;
        if (inv == null) return const SizedBox.shrink();
        final problem = ctl.problem != null;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              key: const Key('invite'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (inv.title.isNotEmpty)
                  Text(
                    inv.title,
                    key: const Key('invite-title'),
                    textAlign: TextAlign.center,
                    style: ui(TypeSize.title, weight: FontWeight.w600, color: problem ? Pal.error : Pal.text1),
                  ),
                if (inv.body.isNotEmpty) ...[
                  const SizedBox(height: Space.s),
                  Text(inv.body, textAlign: TextAlign.center, style: ui(TypeSize.body, color: Pal.text2)),
                ],
                if (inv.actions.isNotEmpty) ...[const SizedBox(height: Space.l), FixButtons(ctl, inv.actions)],
                if (inv.busy != null) ...[
                  const SizedBox(height: Space.m),
                  Text(inv.busy!, key: const Key('invite-busy'), style: ui(TypeSize.small, color: Pal.accent)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// dialogs

class StrisoDialog extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final double maxWidth;
  const StrisoDialog({super.key, required this.title, required this.body, required this.actions, this.maxWidth = 640});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Pal.bg1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ui(TypeSize.title, weight: FontWeight.w600)),
              const SizedBox(height: Space.m),
              body,
              const SizedBox(height: Space.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: Space.s), a],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmSave(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => StrisoDialog(
      title: 'Save touch settings to the Striso?',
      body: Text(
        'The app lets go of the board, the settings are written to it and it restarts (about 15 seconds), then the app '
        'reconnects and reads them back. The previous settings are backed up on this computer first.',
        style: ui(TypeSize.body, color: Pal.text2),
      ),
      actions: [
        Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx, false)),
        Btn('Save', key: const Key('dlg-save-go'), kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return r == true;
}

Future<String?> askName(BuildContext context, {required String title, String initial = '', String action = 'Save'}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => StrisoDialog(
      title: title,
      maxWidth: 420,
      body: InputField(controller: c, hint: 'Name', autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx)),
        Btn(action, kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, c.text)),
      ],
    ),
  );
  c.dispose();
  return r;
}

Future<void> showCode(BuildContext context, AppController ctl, Preset p) async {
  final text = presetToC(p);
  await Clipboard.setData(ClipboardData(text: text));
  ctl.toast('Copied to the clipboard');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StrisoDialog(
      title: 'C code for "${p.name}"',
      maxWidth: 760,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Arrays in parameter index order with names, for the firmware preset tables.', style: ui(TypeSize.body, color: Pal.text2)),
          const SizedBox(height: Space.m),
          Container(
            height: 360,
            decoration: BoxDecoration(color: Pal.bg0, borderRadius: BorderRadius.circular(Radii.small)),
            padding: const EdgeInsets.all(Space.m),
            child: SingleChildScrollView(
              child: SelectableText(text, style: mono(12, color: Pal.text1)),
            ),
          ),
        ],
      ),
      actions: [
        Btn(
          'Copy',
          kind: BtnKind.ghost,
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
  Widget cell(String t, bool left, Color c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
    child: Text(
      t,
      textAlign: left ? TextAlign.left : TextAlign.right,
      style: ui(TypeSize.body, color: c),
    ),
  );
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => StrisoDialog(
      title: 'Suggested key factors',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Brings the ${r.used} keys you pressed to their middle peak ${r.median!.toStringAsFixed(2)}. '
            'Keys you did not press stay as they are; factors stay between 0.6 and 1.6.'
            '${r.skipped.isNotEmpty ? ' ${r.skipped.length} press${r.skipped.length == 1 ? ' was' : 'es were'} too light or too hard to use.' : ''}',
            style: ui(TypeSize.body, color: Pal.text2),
          ),
          const SizedBox(height: Space.m),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            child: SingleChildScrollView(
              child: Table(
                children: [
                  TableRow(
                    children: [
                      for (final (i, h) in ['KEY', 'LAST PEAK', 'FACTOR NOW', 'SUGGESTED'].indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
                          child: Text(h, textAlign: i == 0 ? TextAlign.left : TextAlign.right, style: microStyle()),
                        ),
                    ],
                  ),
                  for (final c in rows)
                    TableRow(
                      children: [
                        cell(c.key.name, true, Pal.text1),
                        cell(c.key.peak.toStringAsFixed(2), false, Pal.text2),
                        cell('×${c.key.factor.toStringAsFixed(2)}', false, Pal.text2),
                        cell('×${c.to.toStringAsFixed(2)}${c.clamped ? ' (limit)' : ''}', false, c.to > c.key.factor ? BoardPal.heatMid : Pal.demo),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        Btn('Cancel', kind: BtnKind.ghost, onPressed: () => Navigator.pop(ctx, false)),
        Btn('Apply', key: const Key('dlg-suggest-apply'), kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return res == true;
}

/// Text input: bg0, hairline, accent when focused, placeholder text3.
class InputField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onSubmitted, onChanged;
  final bool autofocus;
  final int? maxLength;
  final double? width;
  final bool mono;
  const InputField({
    super.key,
    required this.controller,
    required this.hint,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.maxLength = 48,
    this.width,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = mono ? monoStyle() : ui(TypeSize.body);
    return SizedBox(
      width: width,
      height: Sizes.control,
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        maxLength: maxLength,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        style: style,
        cursorColor: Pal.accent,
        decoration: InputDecoration(
          counterText: '',
          isDense: true,
          hintText: hint,
          hintStyle: style.copyWith(color: Pal.text3),
          filled: true,
          fillColor: Pal.bg0,
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: 7),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.small),
            borderSide: const BorderSide(color: Pal.hairline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.small),
            borderSide: const BorderSide(color: Pal.accent),
          ),
        ),
      ),
    );
  }
}

TextStyle monoStyle() => mono(12, color: Pal.text1);

// ---------------------------------------------------------------------------------------------
// the shortcut overlay (?)

const shortcuts = [
  ('1 – 8', 'Engines (voice keys)'),
  ('[  ]', 'Previous / next preset'),
  ('Ctrl+1 / 2 / 3', 'Play, Sound, Setup'),
  ('Ctrl+Z / Ctrl+Y', 'Undo / redo'),
  ('Ctrl+S', 'Save the sound'),
  ('M', 'Mutate'),
  ('B', 'A/B: hold for the preset, release for your edits'),
  ('F or F11', 'Stage mode (Esc leaves)'),
  ('S', 'Settings keys on the board'),
  ('`', 'Console'),
  ('?', 'This list'),
  ('Knobs', 'Drag (Shift fine), scroll, arrows; double-click resets; Alt+click locks'),
];

class ShortcutOverlay extends StatelessWidget {
  final AppController ctl;
  const ShortcutOverlay(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final half = (shortcuts.length / 2).ceil();
    Widget col(Iterable<(String, String)> l) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, what) in l)
          SizedBox(
            height: Sizes.row,
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(k, style: mono(12, color: Pal.accent)),
                ),
                Expanded(
                  child: Text(what, style: ui(TypeSize.body, color: Pal.text2)),
                ),
              ],
            ),
          ),
      ],
    );
    return GestureDetector(
      onTap: () => ctl.setShortcuts(false),
      child: Container(
        key: const Key('shortcuts'),
        color: Pal.scrim,
        alignment: Alignment.center,
        child: Container(
          width: 760,
          padding: const EdgeInsets.all(Space.xl),
          decoration: BoxDecoration(color: Pal.bg1, borderRadius: BorderRadius.circular(Radii.dialog), boxShadow: elevation),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Keyboard', style: ui(TypeSize.title, weight: FontWeight.w600)),
                  const Spacer(),
                  IconBtn(Icons.close, tooltip: 'Close (Esc)', onPressed: () => ctl.setShortcuts(false)),
                ],
              ),
              const SizedBox(height: Space.m),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: col(shortcuts.take(half))),
                  const SizedBox(width: Space.xl),
                  Expanded(child: col(shortcuts.skip(half))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
