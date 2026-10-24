// Every transition of the session's state machine (docs/architecture.md), the refused ones too.
import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/session/session_machine.dart';

void main() {
  final at = DateTime(2026, 10, 24, 12);
  SessionState go(SessionState s, SessionEvent e) => SessionMachine.next(s, e) ?? s;
  bool refused(SessionState s, SessionEvent e) => SessionMachine.next(s, e) == null;

  group('connect', () {
    test('Idle, Failed and Waiting connect in either mode', () {
      for (final from in <SessionState>[
        const Idle(),
        const Idle(IdleWhy.user),
        const Idle(IdleWhy.unplugged),
        const Failed(Mode.striso, FailKind.busy, 'busy'),
        Waiting(Mode.striso, 'back', at),
      ]) {
        for (final m in Mode.values) {
          final s = go(from, ConnectEv(m));
          expect(s, isA<Connecting>(), reason: '$from');
          expect(s.mode, m);
        }
      }
    });
    test('a quiet connect stays quiet through its steps', () {
      var s = go(const Idle(), const ConnectEv(Mode.striso, quiet: true));
      s = go(s, const StepEv('version'));
      expect((s as Connecting).quiet, isTrue);
      expect(s.step, 'version');
    });
    test('connecting or live refuses another connect: a switch is a disconnect first', () {
      expect(refused(const Connecting(Mode.striso, 'x'), const ConnectEv(Mode.virtual)), isTrue);
      expect(refused(const Live(Mode.striso), const ConnectEv(Mode.virtual)), isTrue);
      expect(refused(const Live(Mode.virtual), const ConnectEv(Mode.virtual)), isTrue);
    });
    test('ready makes it live; ready anywhere else is refused', () {
      expect(go(const Connecting(Mode.virtual, 'x'), const ReadyEv()), const TypeMatcher<Live>().having((l) => l.mode, 'mode', Mode.virtual));
      for (final s in <SessionState>[const Idle(), const Live(Mode.striso), const Rebooting(Mode.striso, 'save'), Waiting(Mode.striso, 'w', at)]) {
        expect(refused(s, const ReadyEv()), isTrue, reason: '$s');
      }
    });
    test('steps only while connecting', () {
      expect(refused(const Idle(), const StepEv('x')), isTrue);
      expect(refused(const Live(Mode.striso), const StepEv('x')), isTrue);
    });
  });

  group('errors', () {
    test('a failed connect: Failed with its kind; nothing else', () {
      for (final k in FailKind.values) {
        final s = go(const Connecting(Mode.striso, 'x'), FailEv(k, 'why'));
        expect(s, isA<Failed>().having((f) => f.kind, 'kind', k).having((f) => f.message, 'message', 'why'));
      }
    });
    test('needs a firmware update: failed, then a connect again works', () {
      var s = go(const Connecting(Mode.striso, 'capabilities'), const FailEv(FailKind.needsUpdate, 'This Striso needs a firmware update'));
      expect(s, isA<Failed>());
      s = go(s, const ConnectEv(Mode.striso));
      expect(s, isA<Connecting>());
    });
    test('a fail while live (the board stops answering) and while rebooting (it did not come back)', () {
      expect(go(const Live(Mode.striso), const FailEv(FailKind.other, 'x')), isA<Failed>());
      expect(go(const Rebooting(Mode.striso, 'save'), const FailEv(FailKind.notFound, 'gone')), isA<Failed>());
    });
    test('fail while idle or waiting is refused', () {
      expect(refused(const Idle(), const FailEv(FailKind.other, 'x')), isTrue);
      expect(refused(Waiting(Mode.striso, 'w', at), const FailEv(FailKind.other, 'x')), isTrue);
    });
    test('busy during a quiet connect: wait and try again; a loud one fails', () {
      final s = go(const Connecting(Mode.striso, 'open', quiet: true), WaitEv(Mode.striso, 'busy', at));
      expect(s, isA<Waiting>().having((w) => w.at, 'at', at));
      expect(refused(const Connecting(Mode.striso, 'open'), WaitEv(Mode.striso, 'busy', at)), isTrue);
    });
  });

  group('lost and reboots', () {
    test('lost while live or connecting: idle, unplugged or lost', () {
      expect(go(const Live(Mode.striso), const LostEv()), isA<Idle>().having((i) => i.why, 'why', IdleWhy.unplugged));
      expect(go(const Live(Mode.striso), const LostEv(unplugged: false, note: 'I/O')), isA<Idle>().having((i) => i.why, 'why', IdleWhy.lost));
      expect(go(const Connecting(Mode.virtual, 'x'), const LostEv()), isA<Idle>());
      expect((go(const Live(Mode.striso), const LostEv()) as Idle).lost, isTrue);
    });
    test('unplugged while a reconnect waits: idle', () {
      expect(go(Waiting(Mode.striso, 'w', at), const LostEv()), isA<Idle>());
    });
    test('a reboot (Save, reset): lost is expected, then it comes back through connecting', () {
      var s = go(const Live(Mode.striso), const RebootEv('save'));
      expect(s, isA<Rebooting>().having((r) => r.why, 'why', 'save'));
      expect(go(s, const LostEv()), same(s));
      s = go(s, const ConnectEv(Mode.striso));
      expect(s, isA<Connecting>().having((c) => c.quiet, 'quiet', isTrue));
      s = go(s, const ReadyEv());
      expect(s, isA<Live>());
    });
    test('a reboot comes back only in its own mode', () {
      expect(refused(const Rebooting(Mode.striso, 'save'), const ConnectEv(Mode.virtual)), isTrue);
    });
    test('reboot while idle is refused', () {
      expect(refused(const Idle(), const RebootEv('save')), isTrue);
    });
    test('lost while idle or failed is refused', () {
      expect(refused(const Idle(), const LostEv()), isTrue);
      expect(refused(const Failed(Mode.striso, FailKind.busy, 'x'), const LostEv()), isTrue);
    });
  });

  group('waiting and disconnect', () {
    test('a board back while idle or failed: waiting until due', () {
      expect(go(const Idle(IdleWhy.unplugged), WaitEv(Mode.striso, 'back', at)), isA<Waiting>());
      expect(go(const Failed(Mode.striso, FailKind.busy, 'x'), WaitEv(Mode.striso, 'retry', at)), isA<Waiting>());
      expect(refused(const Live(Mode.striso), WaitEv(Mode.striso, 'x', at)), isTrue);
    });
    test('disconnect from every state ends in Idle with its reason', () {
      for (final s in <SessionState>[
        const Idle(),
        Waiting(Mode.striso, 'w', at),
        const Connecting(Mode.striso, 'x'),
        const Live(Mode.striso),
        const Live(Mode.virtual),
        const Rebooting(Mode.virtual, 'save'),
        const Failed(Mode.striso, FailKind.busy, 'x'),
      ]) {
        expect(go(s, const DisconnectEv()), isA<Idle>().having((i) => i.why, 'why', IdleWhy.user), reason: '$s');
        expect(go(s, const DisconnectEv(IdleWhy.modeSwitch)), isA<Idle>().having((i) => i.why, 'why', IdleWhy.modeSwitch));
      }
    });
  });

  test('the machine applies, notifies, and leaves the state on a refused event', () {
    final m = SessionMachine();
    final seen = <Transition>[];
    m.addListener(seen.add);
    expect(m.on(const ReadyEv()).accepted, isFalse);
    expect(m.state, isA<Idle>());
    m.on(const ConnectEv(Mode.virtual));
    m.on(const ReadyEv());
    expect(m.state, isA<Live>());
    m.on(const DisconnectEv());
    expect(m.state, isA<Idle>());
    expect(seen.map((t) => t.accepted), [false, true, true, true]);
    expect(seen.first.refused, contains('ReadyEv'));
  });
}
