// The window: header, tabs (Play, Sound, Setup), the banner, the console as a pull-up drawer,
// toasts; the keyboard shortcuts and the app-wide animation frame.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'console.dart';
import 'header.dart';
import 'play_tab.dart';
import 'setup_tab.dart';
import 'sound_tab.dart';

class HomePage extends StatefulWidget {
  final AppController ctl;
  const HomePage(this.ctl, {super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  AppController get ctl => widget.ctl;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((t) {
      final dt = math.min(100.0, (t - _last).inMicroseconds / 1000);
      _last = t;
      ctl.frame(clockMs(), dt);
    })..start();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ticker.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    // typing in a field: leave the keys alone
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.widget is EditableText || focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    final kb = HardwareKeyboard.instance;
    final mod = kb.isControlPressed || kb.isMetaPressed;
    final k = e.logicalKey;
    if (mod && k == LogicalKeyboardKey.keyZ) {
      kb.isShiftPressed ? ctl.redo() : ctl.undo();
      return true;
    }
    if (mod && k == LogicalKeyboardKey.keyY) {
      ctl.redo();
      return true;
    }
    if (mod || kb.isAltPressed) return false;
    final tabs = {LogicalKeyboardKey.digit1: AppTab.play, LogicalKeyboardKey.digit2: AppTab.sound, LogicalKeyboardKey.digit3: AppTab.setup};
    if (tabs.containsKey(k)) {
      ctl.setTab(tabs[k]!);
      return true;
    }
    if (k == LogicalKeyboardKey.keyS) {
      ctl.toggleSettings();
      if (ctl.settingsOn) ctl.setTab(AppTab.setup);
      return true;
    }
    if (k == LogicalKeyboardKey.bracketLeft) {
      ctl.stepVoice(-1);
      return true;
    }
    if (k == LogicalKeyboardKey.bracketRight) {
      ctl.stepVoice(1);
      return true;
    }
    if (k == LogicalKeyboardKey.keyM && ctl.hasSound) {
      ctl.mutate();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.panel,
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TopBar(ctl),
              TabStrip(ctl),
              BannerBar(ctl),
              Expanded(
                child: ListenableBuilder(
                  listenable: ctl,
                  builder: (context, _) => AnimatedSwitcher(
                    duration: ctl.options.reducedMotion ? Duration.zero : Timing.fast,
                    child: KeyedSubtree(
                      key: ValueKey(ctl.tab),
                      child: switch (ctl.tab) {
                        AppTab.play => PlayTab(ctl),
                        AppTab.sound => SoundTab(ctl),
                        AppTab.setup => SetupTab(ctl),
                      },
                    ),
                  ),
                ),
              ),
              ConsoleDrawer(ctl),
            ],
          ),
          ToastLayer(ctl),
        ],
      ),
    );
  }
}
