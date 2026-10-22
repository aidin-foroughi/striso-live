// The faceplate: panels in a grid that meets at 1px seams, like the web app's layout, with the
// keyboard shortcuts and the app-wide animation frame.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../theme.dart';
import 'chrome.dart';
import 'console.dart';
import 'live_panel.dart';
import 'side_panel.dart';
import 'sound_panel.dart';
import 'touch_panel.dart';

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
    if (k == LogicalKeyboardKey.keyS) {
      ctl.toggleSettings();
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

  Widget _area(Widget child) => Container(color: Pal.panel, child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.ink,
      body: Stack(
        children: [
          Column(
            children: [
              TopBar(ctl),
              BannerBar(ctl),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    final boardH = (c.maxHeight * 0.64).clamp(420.0, 780.0);
                    Widget grid;
                    if (w > 1280) {
                      // voices | live | side, then touch, then sound. The live panel sets the height of
                      // the first row; the side columns fill it (and scroll inside).
                      grid = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Stack(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(width: 237),
                                  Expanded(child: _area(LivePanel(ctl, boardHeight: boardH))),
                                  const SizedBox(width: 341),
                                ],
                              ),
                              Positioned(left: 0, top: 0, bottom: 0, width: 236, child: _area(VoicesPanel(ctl))),
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                width: 340,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    _area(MorphPanel(ctl)),
                                    const SizedBox(height: 1),
                                    Expanded(child: _area(PresetsPanel(ctl))),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 1),
                          _area(TouchSection(ctl)),
                          const SizedBox(height: 1),
                          _area(SoundPanel(ctl)),
                        ],
                      );
                    } else if (w > 760) {
                      grid = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _area(LivePanel(ctl, boardHeight: boardH)),
                          const SizedBox(height: 1),
                          Stack(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(width: 245),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [_area(MorphPanel(ctl)), const SizedBox(height: 1), _area(PresetsPanel(ctl))],
                                    ),
                                  ),
                                ],
                              ),
                              Positioned(left: 0, top: 0, bottom: 0, width: 244, child: _area(VoicesPanel(ctl))),
                            ],
                          ),
                          const SizedBox(height: 1),
                          _area(TouchSection(ctl)),
                          const SizedBox(height: 1),
                          _area(SoundPanel(ctl)),
                        ],
                      );
                    } else {
                      grid = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _area(LivePanel(ctl, boardHeight: math.max(300, w / 1.15))),
                          const SizedBox(height: 1),
                          _area(VoicesPanel(ctl, scroll: false)),
                          const SizedBox(height: 1),
                          _area(MorphPanel(ctl)),
                          const SizedBox(height: 1),
                          _area(PresetsPanel(ctl)),
                          const SizedBox(height: 1),
                          _area(TouchSection(ctl, narrow: true)),
                          const SizedBox(height: 1),
                          _area(SoundPanel(ctl)),
                        ],
                      );
                    }
                    return Scrollbar(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(color: Pal.seam, child: grid),
                            ConsoleDrawer(ctl),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                              child: Text(
                                '[ ]  previous and next voice,  Ctrl+Z  undo,  Ctrl+Shift+Z  redo,  M  mutate,  S  settings keys. '
                                'Knobs: drag, scroll, arrow keys; double-click resets; Alt+click locks against Mutate.',
                                style: ui(12, color: Pal.faint),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          ToastLayer(ctl),
        ],
      ),
    );
  }
}
