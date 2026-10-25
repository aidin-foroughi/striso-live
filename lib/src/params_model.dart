// The live parameters of the active board (voice, effects, touch, keys) with undo, A/B, Mutate and
// Reset. Pure Dart: the board is reached through [ParamsHost]. The values are the board's: every
// write goes to it at once, and the board's read-back (readBack, after a gesture and whenever its
// change counter moves) replaces what the app holds.

import 'dart:math' as math;

import 'package:striso_core/striso_core.dart';

class ParamSet {
  final String name;
  final List<Param> params;
  final bool missing, complete;
  const ParamSet(this.name, this.params, {this.missing = false, this.complete = true});
  static const empty = ParamSet('', []);
}

const allTargets = [0, 1, 2, 3];
const targetNames = ['voice', 'effect', 'touch', 'key'];

abstract class ParamsHost {
  /// The active board's console (null without a session).
  StrisoClient? get client;
  void toast(String text, [String kind = '']);

  /// Values changed (knobs repaint).
  void valuesChanged();

  /// Something the toolbars show changed (undo/redo, A/B).
  void stateChanged();

  /// The user edited (the edits are kept on this computer soon after).
  void editedByUser();
}

class ParamsModel {
  final ParamsHost host;
  final Map<int, ParamSet> params = {for (final t in allTargets) t: ParamSet.empty};
  final Map<int, Set<String>> locks = {0: <String>{}, 1: <String>{}};
  final History history;

  /// A/B: on while the preset's values (A) sound instead of the edits (B).
  bool abOn = false;
  List<(int, Param, double)> _abEdits = [];
  bool _dirty = false;
  (bool, bool) _undoState = (false, false);
  String mutateScope = '0';
  double mutateAmount = 0.12;
  final math.Random _random;

  /// Values the app sent that the board has not confirmed yet (target, name): shown as pending
  /// until a read-back of their target.
  final _pending = <(int, String)>{};

  bool isPending(int t, Param p) => _pending.contains((t, p.name));
  bool get anyPending => _pending.isNotEmpty;
  List<int> get pendingTargets => {for (final (t, _) in _pending) t}.toList()..sort();

  /// When the app last edited (ms on [clock]): the board's read-back waits for the gesture.
  double editT = -1e9;
  final double Function() clock;

  ParamsModel(this.host, {History? history, required this.clock, math.Random? random})
    : history = history ?? History(),
      _random = random ?? math.Random();

  Param? findParam(int t, String name) => params[t]!.params.where((q) => q.name == name).firstOrNull;

  bool get hasSound => params[0]!.params.isNotEmpty || params[1]!.params.isNotEmpty;

  /// Any voice or effect value differs from the preset's.
  bool get edited => soundTargets.any((t) => params[t]!.params.any((p) => p.value != p.loadValue));

  /// A fresh list from the board: the preset's values are these (A/B ends).
  void load(int t, ParamSet set) {
    params[t] = set;
    _pending.removeWhere((x) => x.$1 == t);
    _endAB();
  }

  void clear() {
    for (final t in allTargets) {
      params[t] = ParamSet.empty;
    }
    history.clear();
    _pending.clear();
    _endAB();
  }

  void _endAB() {
    if (!abOn) return;
    abOn = false;
    _abEdits = [];
  }

  /// The one place values change: model, board (throttled by the client) and history.
  bool setValue(int t, Param p, double v, {bool record = true, bool send = true}) {
    v = conformValue(p, v);
    if (v == p.value) return false;
    if (record) history.record(t, p.name, p.value, v);
    p.value = v;
    if (send && host.client != null) {
      host.client!.setParam(t, p.index, v);
      _pending.add((t, p.name));
    }
    _dirty = true;
    return true;
  }

  /// phase: 'begin' | 'change' | 'end'
  void onEdit(int t, Param p, double v, String phase, [String? label, String? key]) {
    if (abOn) {
      _endAB();
      host.stateChanged();
    }
    if (phase == 'begin') history.begin(label ?? 'Edit', key);
    setValue(t, p, v);
    editT = clock();
    if (phase == 'end') history.commit();
    flush();
  }

  /// After changes: the knobs, the edits kept, the undo buttons.
  void flush() {
    if (!_dirty) return;
    _dirty = false;
    host.valuesChanged();
    if (!abOn) host.editedByUser();
    final u = (history.canUndo, history.canRedo);
    if (u != _undoState) {
      _undoState = u;
      host.stateChanged();
    }
  }

  void _apply(List<(int, String, double)> changes) {
    for (final (t, name, v) in changes) {
      final p = findParam(t, name);
      if (p != null) setValue(t, p, v, record: false);
    }
  }

  static String _lc(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  void undo() {
    final e = history.undo();
    if (e == null) return;
    _apply(e.changes);
    editT = clock();
    flush();
    host.stateChanged();
    host.toast('Undid ${_lc(e.label)}');
  }

  void redo() {
    final e = history.redo();
    if (e == null) return;
    _apply(e.changes);
    editT = clock();
    flush();
    host.stateChanged();
    host.toast('Redid ${_lc(e.label)}');
  }

  void setMutateScope(String s) {
    mutateScope = s;
    host.stateChanged();
  }

  void mutate() {
    final targets = mutateScope == 'both' ? [0, 1] : [int.parse(mutateScope)];
    history.begin('Mutate');
    var n = 0;
    for (final t in targets) {
      for (final (p, v) in mutateValues(params[t]!.params, mutateAmount, _random, locked: locks[t]!)) {
        if (setValue(t, p, v)) n++;
      }
    }
    history.commit();
    editT = clock();
    flush();
    host.stateChanged();
    host.toast(n > 0 ? 'Mutated $n parameters. Undo brings them back.' : 'Nothing to mutate', n > 0 ? '' : 'warn');
  }

  void resetAll() {
    history.begin('Reset all');
    for (final t in soundTargets) {
      for (final p in params[t]!.params) {
        setValue(t, p, p.loadValue);
      }
    }
    history.commit();
    editT = clock();
    flush();
    host.stateChanged();
  }

  void toggleLock(int t, Param p) {
    final set = locks[t]!;
    if (!set.remove(p.name)) set.add(p.name);
    host.toast(set.contains(p.name) ? '${p.name} locked against Mutate' : '${p.name} unlocked');
    host.valuesChanged();
  }

  /// A/B: the preset's values (A) against the edits (B), without touching the history.
  void setAB(bool on) {
    if (on == abOn || host.client == null) return;
    if (on) {
      _abEdits = [
        for (final t in soundTargets)
          for (final p in params[t]!.params)
            if (p.value != p.loadValue) (t, p, p.value),
      ];
      if (_abEdits.isEmpty) {
        host.toast('Nothing edited yet: A and B are the same');
        return;
      }
      abOn = true;
      for (final (t, p, _) in _abEdits) {
        setValue(t, p, p.loadValue, record: false);
      }
    } else {
      abOn = false;
      for (final (t, p, v) in _abEdits) {
        setValue(t, p, v, record: false);
      }
      _abEdits = [];
    }
    editT = clock();
    flush();
    host.stateChanged();
  }

  /// The values as the board reports them, into the parameters the UI holds (their preset values
  /// stay); a list that changed shape is taken as new.
  Future<void> readBack(List<int> targets) async {
    final c = host.client;
    if (c == null) return;
    for (final t in targets) {
      final r = await c.getParams(t);
      if (!identical(c, host.client) || r == null) continue;
      final have = params[t]!;
      // the board has answered for this target: nothing of it is pending any more
      _pending.removeWhere((x) => x.$1 == t);
      if (have.params.length != r.params.length || (t <= 1 && r.name != have.name)) {
        params[t] = ParamSet(r.name, [for (final p in r.params) p..loadValue = p.value], complete: r.complete);
        continue;
      }
      for (var i = 0; i < r.params.length; i++) {
        have.params[i].value = r.params[i].value;
      }
    }
    host.valuesChanged();
  }
}
