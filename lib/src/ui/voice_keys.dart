// The voice keys (Stca, StcA; the firmware's src/synth/voice_keys.hpp): which engine is on which of
// the instrument's voice keys. The board decides and reports; this shows it and asks it.
//   - VoiceKeyEditor: Setup, Settings keys, a selected voice key: its engine and preset, put back
//     to the factory engine, or none.
//   - showPutOnKey: an engine's "Put on key…": the voice keys, free ones first.

import 'package:flutter/material.dart';
import 'package:striso_core/striso_core.dart';

import '../controller.dart';
import '../theme.dart';

/// The label an engine goes by in the app.
String _label(String engine) => engineInfo(engine).label;

/// One line about what a voice key does now.
String voiceKeyStatus(VoiceKeySlot s) => switch (s.state) {
  'ok' => 'Plays ${_label(s.engine!)}${s.preset != null ? ', from ${s.preset}' : ''}.',
  'preset' => '${_label(s.engine!)} has no preset ${s.preset}: the key starts on its first.',
  'missing' => '${_label(s.engine!)} isn’t loaded. The key stays dark until it is.',
  _ => 'No voice on this key.',
};

/// The engine to put on a key from the engine row: the voice it plays now if it is the current
/// engine, else its first.
int? entryFor(AppController ctl, String engine) {
  final cur = ctl.voices.where((v) => v.index == ctl.current && v.engine == engine).firstOrNull;
  return cur?.index ?? ctl.voices.where((v) => v.engine == engine).firstOrNull?.index;
}

/// The voice keys in the order "Put on key…" offers them: free keys, keys whose engine isn't
/// loaded, then the others; in key order within each.
List<VoiceKeySlot> keysToOffer(VoiceKeys vk) {
  int rank(VoiceKeySlot s) => s.empty ? 0 : (s.missing ? 1 : 2);
  return [...vk.slots]..sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.key - b.key);
}

/// "Put on key…" for an engine: a menu of the voice keys at [position].
Future<void> showPutOnKey(BuildContext context, AppController ctl, String engine, Offset position) async {
  if (ctl.voiceKeys.slots.isEmpty) {
    ctl.toast('This firmware has no voice keys to put an engine on', 'warn');
    return;
  }
  final entry = entryFor(ctl, engine);
  if (entry == null) return;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final key = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    color: Pal.bg1,
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
    items: [
      PopupMenuItem<int>(enabled: false, height: Sizes.row, child: Micro('Put ${_label(engine)} on key')),
      for (final s in keysToOffer(ctl.voiceKeys))
        PopupMenuItem<int>(
          key: Key('put-on-${s.key}'),
          value: s.key,
          height: Sizes.row,
          enabled: s.engine != engine,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text('${s.key}', style: ui(TypeSize.body, color: Pal.text1)),
              ),
              Flexible(
                child: Text(
                  s.empty
                      ? 'free'
                      : s.engine == engine
                      ? 'already there'
                      : s.missing
                      ? '${s.engine} (not loaded)'
                      : 'in place of ${_label(s.engine!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(TypeSize.body, color: s.empty ? Pal.text1 : Pal.text2),
                ),
              ),
            ],
          ),
        ),
    ],
  );
  if (key != null) await ctl.putOnKey(key, entry);
}

/// Setup, Settings keys: a voice key, what is on it, and (when it is the selected key) the
/// engines and presets to put there.
class VoiceKeyEditor extends StatelessWidget {
  final AppController ctl;
  final VoiceKeySlot slot;
  final bool editable;
  const VoiceKeyEditor(this.ctl, this.slot, {super.key, this.editable = true});

  @override
  Widget build(BuildContext context) {
    final s = slot;
    final engines = <String>[];
    for (final v in ctl.voices) {
      if (!engines.contains(v.engine)) engines.add(v.engine);
    }
    final presets = s.engine == null ? const <VoiceEntry>[] : ctl.voices.where((v) => v.engine == s.engine).toList();
    final put = editable && ctl.canSend;
    return Column(
      key: Key('voice-key-${s.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(ctl.settingsLayout[s.key]?.title ?? 'Key ${s.key} · Voice', style: ui(TypeSize.title, weight: FontWeight.w600)),
        const SizedBox(height: Space.xs),
        Text(
          voiceKeyStatus(s),
          key: const Key('voice-key-status'),
          style: ui(TypeSize.body, color: s.plays ? Pal.text2 : Pal.text3),
        ),
        if (editable) ...[
          const SizedBox(height: Space.m),
          const Micro('Engine'),
          const SizedBox(height: Space.xs),
          for (final e in engines)
            _Row(
              key: Key('voice-key-engine-$e'),
              label: _label(e),
              dot: engineColor(e),
              current: e == s.engine,
              onTap: put && e != s.engine ? () => ctl.putOnKey(s.key, entryFor(ctl, e)!) : null,
            ),
          if (presets.length > 1) ...[
            const SizedBox(height: Space.m),
            const Micro('Starts on'),
            const SizedBox(height: Space.xs),
            for (final v in presets)
              _Row(
                key: Key('voice-key-preset-${v.index}'),
                label: v.preset ?? v.engine,
                dot: engineColor(v.engine),
                current: s.preset != null ? v.preset == s.preset : v.index == s.first,
                // the key starts there, and it plays now
                onTap: put
                    ? () async {
                        if (await ctl.putOnKey(s.key, v.index)) ctl.selectVoice(v.index);
                      }
                    : null,
              ),
          ],
          const SizedBox(height: Space.s),
          Wrap(
            spacing: Space.s,
            children: [
              if (!s.isFactory && s.factory != null)
                Btn(
                  '↺ ${_label(s.factory!)}',
                  key: const Key('voice-key-factory'),
                  kind: BtnKind.ghost,
                  tooltip: 'Put ${_label(s.factory!)} back on key ${s.key}, as the Striso comes',
                  onPressed: put ? () => ctl.putOnKey(s.key, voiceKeyFactory) : null,
                ),
              if (!s.empty)
                Btn(
                  'No voice',
                  key: const Key('voice-key-clear'),
                  kind: BtnKind.ghost,
                  tooltip: 'Nothing on key ${s.key}',
                  onPressed: put ? () => ctl.putOnKey(s.key, voiceKeyClear) : null,
                ),
            ],
          ),
          if (!ctl.voiceKeys.saved)
            Text(
              'Live now. Save to Striso to keep it.',
              key: const Key('voice-key-unsaved'),
              style: ui(TypeSize.small, color: Pal.text3),
            ),
        ],
      ],
    );
  }
}

class _Row extends StatefulWidget {
  final String label;
  final Color dot;
  final bool current;
  final VoidCallback? onTap;
  const _Row({super.key, required this.label, required this.dot, required this.current, this.onTap});
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: Sizes.row,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        decoration: BoxDecoration(color: _hover && widget.onTap != null ? Pal.bg2 : null, borderRadius: BorderRadius.circular(Radii.small)),
        child: Row(
          children: [
            SizedBox(width: 12, child: widget.current ? Pip(widget.dot) : null),
            Text(
              widget.label,
              style: ui(TypeSize.body, color: widget.current ? Pal.text1 : Pal.text2, weight: widget.current ? FontWeight.w500 : FontWeight.w400),
            ),
          ],
        ),
      ),
    ),
  );
}
