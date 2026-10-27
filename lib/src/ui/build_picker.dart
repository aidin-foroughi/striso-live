// The firmware builds Virtual can run, as sounds to try (docs/flows.md 5): the build chooser that a
// click on Virtual opens (titles and descriptions, the commit each reports, "on your Striso", the
// ones that cannot load greyed with the reason; Install a build or an engine…, Open the firmware
// folder; the engines themselves are in the board's slots, Setup), and the fixes a problem offers
// (docs/flows.md 7), run from the banner and the start screen.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine_library.dart' show packageExt;
import '../firmware_library.dart';
import '../theme.dart';
import 'audio.dart';

/// The build chooser (docs/flows.md 5): what a click on Virtual opens, anchored under
/// [anchor]'s widget. Every build by its title and description, the last played one focused
/// (Enter plays it), the one on the Striso marked, the ones that cannot load greyed with why;
/// Install a release zip… and Open the firmware folder at the bottom. Esc leaves things as they
/// are. Choosing plays.
Future<void> showBuildChooser(BuildContext anchor, AppController ctl) async {
  if (ctl.saving) return;
  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return;
  final rect = Rect.fromPoints(box.localToGlobal(Offset.zero, ancestor: overlay), box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay));
  final position = RelativeRect.fromRect(Rect.fromLTWH(rect.left, rect.bottom + Space.xs, rect.width, 0), Offset.zero & overlay.size);
  final list = ctl.buildList();
  final current = ctl.virtual.libPath;
  final chosen = await showMenu<String>(
    context: anchor,
    position: position,
    color: Pal.bg1,
    initialValue: list.any((b) => b.path == current && b.loadable) ? current : null,
    constraints: const BoxConstraints(minWidth: 360, maxWidth: 600, maxHeight: 640),
    items: [
      PopupMenuItem<String>(enabled: false, height: Sizes.row, child: Text('VIRTUAL · PLAY A BUILD', style: microStyle())),
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
          enabled: b.loadable,
          height: b.build.description != null ? Sizes.row + 16 : Sizes.row,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: 14, child: b.current && ctl.playing == Mode.virtual ? const Pip(Pal.demo, size: 6) : null),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(TypeSize.body, color: b.loadable ? Pal.text1 : Pal.text3, weight: b.current ? FontWeight.w500 : FontWeight.w400),
                    ),
                    if (b.build.description != null)
                      Text(b.build.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: ui(TypeSize.small, color: Pal.text3)),
                  ],
                ),
              ),
              const SizedBox(width: Space.l),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  b.reason ?? [?b.commit, if (b.onStriso) 'on your Striso'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: ui(TypeSize.small, color: b.onStriso && b.reason == null ? Pal.ok : Pal.text3),
                ),
              ),
            ],
          ),
        ),
      PopupMenuItem<String>(enabled: false, height: 9, padding: EdgeInsets.zero, child: Container(height: 1, color: Pal.hairline)),
      PopupMenuItem<String>(
        key: const Key('build-install'),
        value: _install,
        height: Sizes.row,
        enabled: ctl.firmwareDir != null,
        child: Text('Install a build or an engine…', style: ui(TypeSize.body, color: Pal.text2)),
      ),
      PopupMenuItem<String>(
        key: const Key('build-folder'),
        value: _folder,
        height: Sizes.row,
        enabled: ctl.firmwareDir != null,
        child: Text('Open the firmware folder', style: ui(TypeSize.body, color: Pal.text2)),
      ),
    ],
  );
  if (chosen == null) return; // Esc, a click outside: as it was
  if (!anchor.mounted) return;
  if (chosen == _install) return installBuild(anchor, ctl);
  if (chosen == _folder) return openFirmwareFolder(ctl);
  await ctl.useBuild(chosen);
}

const _install = '\u0000install', _folder = '\u0000folder';

/// The Virtual control's label while it plays: "Virtual · Sax v1 ▾" (a long folder name cut;
/// [compact], a narrow window: "Virtual ▾", the title in the tooltip and the status).
String virtualLabel(AppController ctl, {bool compact = false}) {
  if (ctl.playing != Mode.virtual || compact) return 'Virtual ▾';
  var t = ctl.virtual.buildTitle ?? '…';
  if (t.length > 30) t = '${t.substring(0, 29)}…';
  return 'Virtual · $t ▾';
}

/// A file dialog for a release zip (`striso_virtual-<version>-<platform>.zip`), a library, or an
/// engine (a package, .awvapkg, or a zip of them); a build is installed into the firmware folder and
/// played, an engine into the engine library and put into a slot of the board that plays.
Future<void> installBuild(BuildContext context, AppController ctl) async {
  final f = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(label: 'striso_virtual or an engine', extensions: ['zip', virtualLibName().split('.').last, packageExt]),
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
    case Fix.pickBuild || Fix.playVirtual:
      await showBuildChooser(context, ctl); // the one place a build is chosen
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
          Builder(
            builder: (ctx) => Btn(
              f.label,
              key: Key('fix-${f.name}'),
              kind: i == 0 && lead ? BtnKind.primary : BtnKind.ghost,
              onPressed: ctl.saving ? null : () => runFix(ctx, ctl, f),
            ),
          ),
        ],
      ],
    );
  }
}
