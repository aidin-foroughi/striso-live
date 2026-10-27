// The chord readout behind the live view: held keys must be stable for 70 ms before they are
// named (no flicker in rolled chords) and for 160 ms before they join the progression; a key
// finder listens along.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:striso_core/striso_core.dart';

class ProgEntry {
  Harmony a;
  final List<SNote> notes;
  ProgEntry(this.a, this.notes);
}

class HarmonyTracker extends ChangeNotifier {
  final LiveState live;
  MusicKey? key;
  String _candSig = '';
  double _candT = 0;
  Harmony? shown;
  List<SNote> shownNotes = const [];
  String _shownSig = '';
  bool _pushed = false, released = false;
  final prog = <ProgEntry>[];
  final finder = KeyFinder(20);
  double _lastT = 0, _suggestT = 0;
  KeyEstimate? suggestion;

  HarmonyTracker(this.live);

  List<(int, SNote)> heldNotes(double now) {
    final out = <(int, SNote)>[];
    final l = live.layout;
    if (l == null) return out;
    for (final id in l.keyIds) {
      if (live.down[id] == 1 && live.pres[id] >= 0.02 && now - live.onT[id] >= 40) {
        out.add((id, SNote(l.keyTpc(id, live.transposeFifths), l.startNote + l.pitchOf(id) + live.transpose)));
      }
    }
    return out;
  }

  void setKey(MusicKey? k) {
    key = k;
    for (final e in prog) {
      e.a = analyze(e.notes, key) ?? e.a;
    }
    if (shown != null) shown = analyze(shownNotes, key);
    _updateSuggestion();
    notifyListeners();
  }

  void clearProgression() {
    prog.clear();
    notifyListeners();
  }

  void reset() {
    _candSig = '';
    _shownSig = '';
    shown = null;
    shownNotes = const [];
    released = false;
    notifyListeners();
  }

  void frame(double now) {
    final held = heldNotes(now);
    final dt = (now - _lastT) / 1000;
    _lastT = now;
    if (dt > 0 && dt < 0.5 && held.isNotEmpty) {
      finder.add([for (final (id, n) in held) (pcOf(n.tpc), math.min(1.0, 0.3 + live.pres[id]))], dt);
    }
    if (now - _suggestT > 1000) {
      _suggestT = now;
      if (_updateSuggestion()) notifyListeners();
    }
    final sig = held.map((h) => h.$1).join(',');
    if (sig != _candSig) {
      _candSig = sig;
      _candT = now;
      return;
    }
    if (now - _candT < 70) return;
    if (sig == _shownSig) {
      if (sig.isNotEmpty && !_pushed && now - _candT >= 160 && shown?.kind == HarmonyKind.chord) {
        _pushed = true;
        _push(shown!, shownNotes);
      }
      return;
    }
    _shownSig = sig;
    if (held.isEmpty) {
      released = true; // keep showing the last chord
      notifyListeners();
      return;
    }
    released = false;
    shownNotes = [for (final h in held) h.$2];
    shown = analyze(shownNotes, key);
    _pushed = false;
    notifyListeners();
  }

  void _push(Harmony a, List<SNote> notes) {
    if (prog.isNotEmpty && prog.last.a.name == a.name) return;
    prog.add(ProgEntry(a, notes));
    if (prog.length > 12) prog.removeAt(0);
    notifyListeners();
  }

  /// Returns true when the suggestion changed.
  bool _updateSuggestion() {
    final est = finder.total > 3 ? finder.estimate() : null;
    final k = key;
    final same = est != null && k != null && pcOf(k.tonic) == est.pc && (est.mode == 'major' ? k.ref == 'major' : k.ref == 'minor');
    final next = (est == null || est.score < 0.7 || same) ? null : est;
    final changed = next?.name != suggestion?.name;
    suggestion = next;
    return changed;
  }
}
