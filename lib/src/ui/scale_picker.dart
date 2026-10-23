// The scale picker: about 66 scales in grouped sections, type to search, each row with its degree
// formula ("1 2 ♭3 4 5 ♭6 ♮7") and a tooltip.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_core/striso_core.dart';

import '../theme.dart';
import 'chrome.dart';

class ScalePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final double width;
  const ScalePicker({super.key, required this.value, required this.onChanged, this.width = 180});

  @override
  Widget build(BuildContext context) {
    final label = value == 'off' ? 'No key' : scales[value]!.label;
    return Tooltip(
      message: value == 'off' ? 'Pick a scale: highlighting, degrees and roman numerals' : '${scales[value]!.label}: ${scaleFormula(value)}',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const Key('key-scale'),
          onTap: () => _open(context),
          child: SelectFace(label: label, width: width),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height + Space.xs));
    final picked = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.transparent,
      transitionDuration: Timing.quick,
      pageBuilder: (ctx, _, _) => _ScaleMenu(at: at, value: value),
    );
    if (picked != null) onChanged(picked);
  }
}

class _ScaleMenu extends StatefulWidget {
  final Offset at;
  final String value;
  const _ScaleMenu({required this.at, required this.value});
  @override
  State<_ScaleMenu> createState() => _ScaleMenuState();
}

class _ScaleMenuState extends State<_ScaleMenu> {
  final _q = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _match(String id) {
    final q = _q.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    final s = scales[id]!;
    return s.label.toLowerCase().contains(q) ||
        s.key.toLowerCase().contains(q) ||
        scaleFormula(id).replaceAll('♭', 'b').replaceAll('♯', '#').contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final searching = _q.text.trim().isNotEmpty;
    final rows = <Widget>[if (!searching) _row('off', 'No key', '')];
    if (searching) {
      final seen = <String>{};
      for (final (_, ids) in scaleGroups) {
        for (final id in ids) {
          if (_match(id) && seen.add(id)) rows.add(_row(id, scales[id]!.label, scaleFormula(id)));
        }
      }
      if (rows.isEmpty) {
        rows.add(
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text('No scale matches.', style: ui(TypeSize.body, color: Pal.text2)),
          ),
        );
      }
    } else {
      for (final (group, ids) in scaleGroups) {
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.xs), child: Micro(group)));
        for (final id in ids) {
          rows.add(_row(id, scales[id]!.label, scaleFormula(id)));
        }
      }
    }
    const w = 400.0;
    final left = widget.at.dx.clamp(Space.s, size.width - w - Space.s);
    final top = widget.at.dy.clamp(Space.s, size.height - 200);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          height: (size.height - top - Space.l).clamp(200.0, 560.0),
          child: Material(
            color: Pal.bg1,
            borderRadius: BorderRadius.circular(Radii.popover),
            elevation: 0,
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.popover), boxShadow: elevation),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(Space.s),
                    child: Focus(
                      onKeyEvent: (n, e) {
                        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter) {
                          final first = scaleGroups.expand((g) => g.$2).where(_match).firstOrNull;
                          if (first != null) Navigator.pop(context, first);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: InputField(controller: _q, hint: 'Search scales (name or 1 2 b3…)', autofocus: true, maxLength: 40),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: Space.s),
                      children: rows,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(String id, String label, String formula) =>
      _ScaleRow(key: Key('scale-$id'), label: label, formula: formula, selected: id == widget.value, onTap: () => Navigator.pop(context, id));
}

class _ScaleRow extends StatefulWidget {
  final String label, formula;
  final bool selected;
  final VoidCallback onTap;
  const _ScaleRow({super.key, required this.label, required this.formula, required this.selected, required this.onTap});
  @override
  State<_ScaleRow> createState() => _ScaleRowState();
}

class _ScaleRowState extends State<_ScaleRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.formula.isEmpty ? '' : '${widget.label}: ${widget.formula}',
      waitDuration: const Duration(milliseconds: 900),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: Sizes.row,
            color: _hover ? Pal.bg2 : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(
                      TypeSize.body,
                      color: widget.selected ? Pal.accent : Pal.text1,
                      weight: widget.selected ? FontWeight.w500 : FontWeight.w400,
                    ),
                  ),
                ),
                Text(widget.formula, style: ui(TypeSize.small, color: Pal.text3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
