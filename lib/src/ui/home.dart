// The window: the header with the tabs, the persistent problem strip, the tab content (or stage
// mode), the console pulled up from the bottom edge, toasts and the shortcut overlay; the
// keyboard shortcuts and the app-wide animation frame.

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
import 'stage.dart';

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

  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  ];

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    // B held: hear A (the preset as loaded); released: back to B
    if (k == LogicalKeyboardKey.keyB && e is KeyUpEvent && ctl.abOn) {
      ctl.setAB(false);
      return true;
    }
    if (e is! KeyDownEvent) return false;
    // typing in a field: leave the keys alone
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.widget is EditableText || focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    final kb = HardwareKeyboard.instance;
    final mod = kb.isControlPressed || kb.isMetaPressed;
    if (mod) {
      if (k == LogicalKeyboardKey.keyZ) {
        kb.isShiftPressed ? ctl.redo() : ctl.undo();
        return true;
      }
      if (k == LogicalKeyboardKey.keyY) {
        ctl.redo();
        return true;
      }
      if (k == LogicalKeyboardKey.keyS) {
        if (ctl.lastSound != null && ctl.connected) {
          ctl.saveCurrent(ctl.lastSound!);
        } else {
          saveSoundAs(context, ctl);
        }
        return true;
      }
      final i = _digits.indexOf(k);
      if (i >= 0 && i < 3) {
        ctl.setStage(false);
        ctl.setTab(AppTab.values[i]);
        return true;
      }
      return false;
    }
    if (kb.isAltPressed) return false;
    if (k == LogicalKeyboardKey.escape) {
      if (ctl.shortcutsOpen) return _done(() => ctl.setShortcuts(false));
      if (ctl.stage) return _done(() => ctl.setStage(false));
      if (ctl.consoleOpen) return _done(() => ctl.setConsole(false));
      return false;
    }
    if (k == LogicalKeyboardKey.f11 || k == LogicalKeyboardKey.keyF) return _done(() => ctl.setStage(!ctl.stage));
    if (k == LogicalKeyboardKey.backquote) return _done(() => ctl.setConsole(!ctl.consoleOpen));
    if (e.character == '?' || (k == LogicalKeyboardKey.slash && kb.isShiftPressed)) return _done(() => ctl.setShortcuts(!ctl.shortcutsOpen));
    final i = _digits.indexOf(k);
    if (i >= 0) {
      final engines = ctl.engines();
      if (i < engines.length && engines[i].count > 0) ctl.selectEngine(engines[i].engine);
      return true;
    }
    if (k == LogicalKeyboardKey.keyB) return _done(() => ctl.setAB(true));
    if (k == LogicalKeyboardKey.keyS) {
      final on = !ctl.settingsOn;
      ctl.setSetupMode(on ? SetupMode.settings : SetupMode.sensitivity);
      if (on) ctl.setTab(AppTab.setup);
      return true;
    }
    if (k == LogicalKeyboardKey.bracketLeft) return _done(() => ctl.stepVoice(-1));
    if (k == LogicalKeyboardKey.bracketRight) return _done(() => ctl.stepVoice(1));
    if (k == LogicalKeyboardKey.keyM && ctl.hasSound) return _done(ctl.mutate);
    return false;
  }

  bool _done(VoidCallback f) {
    f();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = ctl.options.reducedMotion || MediaQuery.maybeDisableAnimationsOf(context) == true;
    return Scaffold(
      backgroundColor: Pal.bg0,
      body: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => Stack(
          children: [
            AnimatedSwitcher(
              duration: reduced ? Timing.reduced : Timing.stage,
              switchInCurve: Timing.curveOpen,
              switchOutCurve: Timing.curveOpen,
              child: ctl.stage
                  ? StageView(ctl)
                  : Column(
                      key: const Key('panel'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TopBar(ctl),
                        BannerBar(ctl),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: reduced ? Timing.reduced : Timing.tab,
                            switchInCurve: Timing.curveTab,
                            transitionBuilder: (child, a) => FadeTransition(
                              opacity: a,
                              child: reduced
                                  ? child
                                  : SlideTransition(
                                      position: Tween(begin: const Offset(0, 0.004), end: Offset.zero).animate(a),
                                      child: child,
                                    ),
                            ),
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
                        ConsoleDrawer(ctl),
                      ],
                    ),
            ),
            ToastLayer(ctl),
            if (ctl.shortcutsOpen) Positioned.fill(child: ShortcutOverlay(ctl)),
          ],
        ),
      ),
    );
  }
}
