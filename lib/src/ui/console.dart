// The console drawer: diagnostics, the log (every app error lands here and in the log file),
// and one console command at a time.

import 'package:flutter/material.dart';

import '../app_log.dart';
import '../controller.dart';
import '../theme.dart';

class ConsoleDrawer extends StatefulWidget {
  final AppController ctl;
  const ConsoleDrawer(this.ctl, {super.key});
  @override
  State<ConsoleDrawer> createState() => _ConsoleDrawerState();
}

class _ConsoleDrawerState extends State<ConsoleDrawer> {
  bool open = false;
  final _cmd = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _cmd.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _cmd.text;
    _cmd.clear();
    await widget.ctl.consoleSend(t);
  }

  @override
  Widget build(BuildContext context) {
    final ctl = widget.ctl;
    return Container(
      decoration: const BoxDecoration(
        color: Pal.panel,
        border: Border(
          bottom: BorderSide(color: Pal.seam),
          top: BorderSide(color: Pal.seam),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key('console-toggle'),
              onTap: () => setState(() => open = !open),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Row(
                  children: [
                    Icon(open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Pal.muted),
                    Text('Console', style: ui(13, color: Pal.muted)),
                    const Spacer(),
                    if (appLog.filePath != null) Text('log: ${appLog.filePath}', style: ui(11.5, color: Pal.faint)),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListenableBuilder(
                    listenable: ctl.stats,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(ctl.diagnosticsText(), key: const Key('diag'), style: mono(12)),
                    ),
                  ),
                  Container(
                    height: 160,
                    decoration: BoxDecoration(
                      color: Pal.ink,
                      border: Border.all(color: Pal.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: ListenableBuilder(
                      listenable: appLog,
                      builder: (context, _) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
                        });
                        return SelectionArea(
                          child: ListView.builder(
                            controller: _scroll,
                            itemCount: appLog.lines.length,
                            itemBuilder: (context, i) {
                              final l = appLog.lines[i];
                              final c = switch (l.kind) {
                                LogKind.err => Pal.danger,
                                LogKind.out => Pal.honey,
                                LogKind.info => const Color(0xFFCFC8E2),
                              };
                              return Text('${l.stamp}  ${l.text}', style: mono(12, color: c));
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('Send Stc +', style: ui(12.5, color: Pal.muted)),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 70,
                        height: 28,
                        child: TextField(
                          key: const Key('console-cmd'),
                          controller: _cmd,
                          maxLength: 4,
                          onSubmitted: (_) => _send(),
                          style: mono(13, color: Pal.text),
                          decoration: InputDecoration(
                            counterText: '',
                            isDense: true,
                            hintText: 'I',
                            hintStyle: mono(13, color: Pal.faint),
                            filled: true,
                            fillColor: Pal.ink,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Pal.line),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Pal.glacier),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Btn('Send', small: true, onPressed: _send),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'One command character, e.g. I threads or P profile. Bootloader, DFU and calibration are blocked here.',
                          style: ui(12.5, color: Pal.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
