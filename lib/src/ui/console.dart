// The console drawer (DESIGN.md 3): pulled up from the bottom edge (a 6 px grab zone, a hairline
// on hover), 240 px, mono 12 on bg1. The header row holds Clear, the log path and the Stc + field;
// the diagnostics line sits above the log. Every app error lands here and in the log file.

import 'package:flutter/material.dart';

import '../app_log.dart';
import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';

class ConsoleDrawer extends StatefulWidget {
  final AppController ctl;
  const ConsoleDrawer(this.ctl, {super.key});
  @override
  State<ConsoleDrawer> createState() => _ConsoleDrawerState();
}

class _ConsoleDrawerState extends State<ConsoleDrawer> {
  final _cmd = TextEditingController();
  final _scroll = ScrollController();
  bool _hover = false;

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
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final open = ctl.consoleOpen;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Tooltip(
              message: open ? 'Close the console (`)' : 'Console (`)',
              waitDuration: const Duration(milliseconds: 700),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  key: const Key('console-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => ctl.setConsole(!open),
                  onVerticalDragEnd: (d) => ctl.setConsole((d.primaryVelocity ?? 0) < 0 ? true : ((d.primaryVelocity ?? 0) > 0 ? false : !open)),
                  child: Container(
                    height: 6,
                    alignment: Alignment.topCenter,
                    child: Container(height: 1, color: _hover || open ? Pal.hairline : Colors.transparent),
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: Timing.open,
              curve: Timing.curveOpen,
              alignment: Alignment.topCenter,
              child: !open
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      height: Sizes.console,
                      color: Pal.bg1,
                      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, Space.s),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Text('Console', style: ui(TypeSize.title, weight: FontWeight.w600)),
                              const SizedBox(width: Space.m),
                              Btn('Clear', kind: BtnKind.ghost, onPressed: appLog.clear),
                              const SizedBox(width: Space.m),
                              if (appLog.filePath != null)
                                Expanded(
                                  child: SelectableText(appLog.filePath!, maxLines: 1, style: mono(11, color: Pal.text3)),
                                )
                              else
                                const Spacer(),
                              Text('Stc +', style: mono(12)),
                              const SizedBox(width: Space.xs),
                              InputField(
                                key: const Key('console-cmd'),
                                controller: _cmd,
                                hint: 'I',
                                width: 64,
                                maxLength: 4,
                                mono: true,
                                onSubmitted: (_) => _send(),
                              ),
                              const SizedBox(width: Space.xs),
                              Btn(
                                'Send',
                                kind: BtnKind.ghost,
                                tooltip: 'One command character, e.g. I threads or P profile. B, D and C are blocked here.',
                                onPressed: _send,
                              ),
                              IconBtn(Icons.close, tooltip: 'Close (`)', onPressed: () => ctl.setConsole(false)),
                            ],
                          ),
                          ListenableBuilder(
                            listenable: ctl.stats,
                            builder: (context, _) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: Space.xs),
                              child: Text(
                                ctl.diagnosticsText(),
                                key: const Key('diag'),
                                maxLines: 2,
                                style: mono(11, color: Pal.text3),
                              ),
                            ),
                          ),
                          Expanded(
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
                                        LogKind.err => Pal.error,
                                        LogKind.out => Pal.accent,
                                        LogKind.info => Pal.text2,
                                      };
                                      return Text('${l.stamp}  ${l.text}', style: mono(12, color: c));
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
