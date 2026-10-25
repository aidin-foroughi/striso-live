// The firmware builds Virtual can run, as sounds to try (docs/flows.md 5): the row at the top of
// the Play tab's left column (the build's title, its description, the ⇄ back to the build played
// before), the build menu (titles, the commit each reports, "on your Striso", the ones that cannot
// load greyed with the reason, Install a release zip…, Open the firmware folder), and the fixes a
// problem offers (docs/flows.md 7), run from the banner and the start screen.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../firmware_library.dart';
import '../theme.dart';
import 'audio.dart';

/// The build row of the Play tab's left column (Virtual only).
class BuildRow extends StatelessWidget {
  final AppController ctl;
  const BuildRow(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final title = ctl.virtual.isMock ? 'The Dart mock' : (ctl.virtual.buildTitle ?? 'No build');
    final desc = ctl.virtual.libPath == null ? null : buildOf(ctl.virtual.libPath!).description;
    final prev = ctl.previousBuild;
    final prevTitle = prev == null ? null : buildOf(prev).title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Micro('Virtual', color: Pal.demo),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            Expanded(
              child: BuildMenu(
                ctl,
                child: LayoutBuilder(builder: (context, box) => SelectFace(label: title, width: box.maxWidth)),
              ),
            ),
            if (prevTitle != null) ...[
              const SizedBox(width: Space.xs),
              IconBtn(
                Icons.swap_horiz,
                key: const Key('build-swap'),
                tooltip: 'Back to $prevTitle, on the same key',
                onPressed: ctl.saving ? null : ctl.swapBuild,
              ),
            ],
          ],
        ),
        if (desc != null) ...[
          const SizedBox(height: Space.xs),
          Tooltip(
            message: desc,
            waitDuration: Timing.tooltipWait,
            child: Text(desc, key: const Key('build-description'), maxLines: 2, overflow: TextOverflow.ellipsis, style: ui(TypeSize.small, color: Pal.text3)),
          ),
        ],
      ],
    );
  }
}

/// The build menu around [child]: choosing a build plays it.
class BuildMenu extends StatelessWidget {
  final AppController ctl;
  final Widget child;
  final String? tooltip;
  const BuildMenu(this.ctl, {super.key, required this.child, this.tooltip});

  static const _install = '\u0000install', _folder = '\u0000folder';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('build-menu'),
      tooltip: tooltip ?? 'The firmware build Virtual runs: pick one to play it (the same key, its sound)',
      color: Pal.bg1,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 560, maxHeight: 600),
      enabled: !ctl.saving,
      onSelected: (v) async {
        if (v == _install) return installBuild(context, ctl);
        if (v == _folder) return openFirmwareFolder(ctl);
        await ctl.useBuild(v);
      },
      itemBuilder: (context) {
        final list = ctl.buildList();
        return [
          PopupMenuItem<String>(enabled: false, height: Sizes.row, child: Text('BUILDS', style: microStyle())),
          if (list.isEmpty)
            PopupMenuItem<String>(
              enabled: false,
              height: Sizes.row,
              child: Text('No builds in the firmware folder yet', key: const Key('build-none'), style: ui(TypeSize.body, color: Pal.text3)),
            ),
          for (final b in list)
            PopupMenuItem<String>(
              key: Key('build-${b.build.name}'),
              value: b.path,
              enabled: b.loadable && !b.current,
              height: Sizes.row,
              child: Row(
                children: [
                  SizedBox(width: 14, child: b.current ? const Pip(Pal.demo, size: 6) : null),
                  Flexible(
                    flex: 3,
                    child: Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(TypeSize.body, color: b.loadable ? (b.current ? Pal.text1 : Pal.text1) : Pal.text3, weight: b.current ? FontWeight.w500 : FontWeight.w400),
                    ),
                  ),
                  const SizedBox(width: Space.m),
                  Flexible(
                    flex: 2,
                    child: Text(
                      b.reason ?? [?b.commit, if (b.onStriso) 'on your Striso'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: ui(TypeSize.small, color: b.reason != null ? Pal.text3 : (b.onStriso ? Pal.ok : Pal.text3)),
                    ),
                  ),
                ],
              ),
            ),
          const PopupMenuDivider(height: 9),
          PopupMenuItem<String>(
            value: _install,
            height: Sizes.row,
            enabled: ctl.firmwareDir != null,
            child: Text('Install a release zip…', style: ui(TypeSize.body, color: Pal.text2)),
          ),
          PopupMenuItem<String>(
            value: _folder,
            height: Sizes.row,
            enabled: ctl.firmwareDir != null,
            child: Text('Open the firmware folder', style: ui(TypeSize.body, color: Pal.text2)),
          ),
        ];
      },
      child: child,
    );
  }
}

/// A file dialog for a release zip (`striso_virtual-<version>-<platform>.zip`) or a library; what
/// is picked is installed into the firmware folder and played.
Future<void> installBuild(BuildContext context, AppController ctl) async {
  final f = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(label: 'striso_virtual', extensions: ['zip', virtualLibName().split('.').last]),
    ],
  );
  if (f != null) await ctl.installAndUseFirmware(f.path);
}

Future<void> openFirmwareFolder(AppController ctl) async {
  final dir = ctl.firmwareDir;
  if (dir == null) return;
  Directory(dir).createSync(recursive: true);
  await revealFile('$dir${Platform.pathSeparator}.');
}

/// Opens [url] in the browser.
Future<void> openUrl(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else {
      await Process.start('xdg-open', [url]);
    }
  } catch (_) {}
}

/// Runs a fix: the controller's own, or the ones that need a dialog or a menu.
Future<void> runFix(BuildContext context, AppController ctl, Fix f) async {
  switch (f) {
    case Fix.installBuild:
      await installBuild(context, ctl);
    case Fix.openFolder:
      await openFirmwareFolder(ctl);
    case Fix.copyVersion:
      final v = ctl.strisoVersion;
      if (v == null) return;
      await Clipboard.setData(ClipboardData(text: [v.line, ...v.extra].join('\n')));
      ctl.toast('Copied to the clipboard');
    case Fix.getRuntime:
      await openUrl('https://aka.ms/vs/17/release/vc_redist.x64.exe');
    case Fix.pickBuild:
      break; // a BuildMenu button
    default:
      await ctl.fix(f);
  }
}

/// The fix buttons of a problem or the start screen: the first one primary when [lead] is on;
/// "Pick a build" opens the build menu.
class FixButtons extends StatelessWidget {
  final AppController ctl;
  final List<Fix> fixes;
  final bool lead;
  const FixButtons(this.ctl, this.fixes, {super.key, this.lead = true});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, f) in fixes.indexed) ...[
          if (i > 0) const SizedBox(width: Space.s),
          if (f == Fix.pickBuild)
            BuildMenu(
              ctl,
              tooltip: 'Pick a build to play',
              child: Btn(f.label, key: Key('fix-${f.name}'), kind: i == 0 && lead ? BtnKind.primary : BtnKind.ghost, onPressed: null, pressed: false),
            )
          else
            Btn(
              f.label,
              key: Key('fix-${f.name}'),
              kind: i == 0 && lead ? BtnKind.primary : BtnKind.ghost,
              onPressed: ctl.saving ? null : () => runFix(context, ctl, f),
            ),
        ],
      ],
    );
  }
}
