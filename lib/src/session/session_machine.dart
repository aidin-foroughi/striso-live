// The session's states and every transition between them, in one place (docs/architecture.md).
// Pure Dart, no I/O: the Session drives it and acts on what it allows.

/// Striso: the hardware over its USB console. Virtual: the firmware as a soft instrument on the
/// computer (no USB session with any board).
enum Mode { striso, virtual }

/// Why the session is idle: never connected; the user let go of the Striso (Disconnect: it stays
/// away); the user stopped Virtual (a Striso plugged in from now on connects by itself); unplugged;
/// the connection was lost; one mode ended for the other.
enum IdleWhy { start, user, stopped, unplugged, lost, modeSwitch }

/// What failed.
enum FailKind { busy, noDriver, notFound, needsUpdate, library, noUsb, other }

sealed class SessionState {
  const SessionState();

  /// The mode the state is about (null when idle).
  Mode? get mode => null;
  bool get live => false;
}

class Idle extends SessionState {
  final IdleWhy why;
  final String? note;
  const Idle([this.why = IdleWhy.start, this.note]);
  bool get lost => why == IdleWhy.unplugged || why == IdleWhy.lost;
  @override
  String toString() => 'Idle(${why.name}${note != null ? ': $note' : ''})';
}

/// A connect is due at [at] (a Striso came back; or it was busy and is tried again).
class Waiting extends SessionState {
  @override
  final Mode mode;
  final String why;
  final DateTime at;
  const Waiting(this.mode, this.why, this.at);
  @override
  String toString() => 'Waiting(${mode.name}, $why)';
}

class Connecting extends SessionState {
  @override
  final Mode mode;
  final String step;

  /// A quiet connect (at start, a reconnect): a busy board waits instead of failing loudly.
  final bool quiet;
  const Connecting(this.mode, this.step, {this.quiet = false});
  @override
  String toString() => 'Connecting(${mode.name}, $step)';
}

class Live extends SessionState {
  @override
  final Mode mode;
  const Live(this.mode);
  @override
  bool get live => true;
  @override
  String toString() => 'Live(${mode.name})';
}

/// The board goes away on purpose (Save, a reset) and comes back by itself.
class Rebooting extends SessionState {
  @override
  final Mode mode;
  final String why;
  const Rebooting(this.mode, this.why);
  @override
  String toString() => 'Rebooting(${mode.name}, $why)';
}

class Failed extends SessionState {
  @override
  final Mode mode;
  final FailKind kind;
  final String message;
  const Failed(this.mode, this.kind, this.message);
  @override
  String toString() => 'Failed(${mode.name}, ${kind.name}: $message)';
}

sealed class SessionEvent {
  const SessionEvent();
}

/// The user (or the app at start) wants [mode] now.
class ConnectEv extends SessionEvent {
  final Mode mode;
  final bool quiet;
  const ConnectEv(this.mode, {this.quiet = false});
}

/// The board was found while idle (or busy): connect at [at].
class WaitEv extends SessionEvent {
  final Mode mode;
  final String why;
  final DateTime at;
  const WaitEv(this.mode, this.why, this.at);
}

/// A step of the connect (for the status).
class StepEv extends SessionEvent {
  final String step;
  const StepEv(this.step);
}

/// The board answers and has what the app needs.
class ReadyEv extends SessionEvent {
  const ReadyEv();
}

class FailEv extends SessionEvent {
  final FailKind kind;
  final String message;
  const FailEv(this.kind, this.message);
}

/// The connection went away without being asked to (unplugged or an I/O error).
class LostEv extends SessionEvent {
  final bool unplugged;
  final String? note;
  const LostEv({this.unplugged = true, this.note});
}

class RebootEv extends SessionEvent {
  final String why;
  const RebootEv(this.why);
}

/// The user's Disconnect (or a mode switch, or quitting).
class DisconnectEv extends SessionEvent {
  final IdleWhy why;
  const DisconnectEv([this.why = IdleWhy.user]);
}

/// The result of an event: the new state, or why it was refused.
class Transition {
  final SessionState from, to;
  final SessionEvent event;
  final bool accepted;
  final String? refused;
  const Transition(this.from, this.to, this.event, {this.accepted = true, this.refused});
}

class SessionMachine {
  SessionState _state;
  final _listeners = <void Function(Transition)>[];

  SessionMachine([this._state = const Idle()]);

  SessionState get state => _state;

  void addListener(void Function(Transition) f) => _listeners.add(f);
  void removeListener(void Function(Transition) f) => _listeners.remove(f);

  /// What [e] does in [s]: the next state, or null when it is refused.
  static SessionState? next(SessionState s, SessionEvent e) {
    switch ((s, e)) {
      // connect: from anything that is not already connecting or live in that mode
      case (Idle() || Failed() || Waiting(), ConnectEv(:final mode, :final quiet)):
        return Connecting(mode, 'starting', quiet: quiet);
      case (Rebooting(mode: final m), ConnectEv(:final mode)) when m == mode:
        return Connecting(mode, 'coming back', quiet: true);
      case (Idle() || Failed(), WaitEv(:final mode, :final why, :final at)):
        return Waiting(mode, why, at);
      // a busy board during a quiet connect waits for the next try
      case (Connecting(:final mode, quiet: true), WaitEv(mode: final m, :final why, :final at)) when m == mode:
        return Waiting(mode, why, at);
      case (Connecting(:final mode, :final quiet), StepEv(:final step)):
        return Connecting(mode, step, quiet: quiet);
      case (Connecting(:final mode), ReadyEv()):
        return Live(mode);
      case (Connecting(:final mode) || Rebooting(:final mode), FailEv(:final kind, :final message)):
        return Failed(mode, kind, message);
      case (Live(:final mode), FailEv(:final kind, :final message)):
        return Failed(mode, kind, message);
      case (Connecting() || Live() || Waiting(), LostEv(:final unplugged, :final note)):
        return Idle(unplugged ? IdleWhy.unplugged : IdleWhy.lost, note);
      case (Rebooting(), LostEv()):
        return s; // expected: the board restarts
      case (Live(:final mode), RebootEv(:final why)):
        return Rebooting(mode, why);
      case (Connecting(:final mode), RebootEv(:final why)):
        return Rebooting(mode, why);
      case (_, DisconnectEv(:final why)):
        return Idle(why);
      default:
        return null;
    }
  }

  /// Applies [e]; returns the transition (refused ones leave the state as it is).
  Transition on(SessionEvent e) {
    final from = _state;
    final to = next(from, e);
    final t = to == null
        ? Transition(from, from, e, accepted: false, refused: '${e.runtimeType} in $from')
        : Transition(from, to, e);
    if (to != null) _state = to;
    for (final f in List.of(_listeners)) {
      f(t);
    }
    return t;
  }
}
