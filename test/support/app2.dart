// What the controller, flow and Setup tests need besides test/support/virtual.dart: the virtual
// board's cable pulled (a restart of the board while USB says nothing is there), and the few cases
// the real firmware cannot be: a Striso that is busy, an old firmware, a reply the current
// firmware never gives. Those are canned replies only: no state, no firmware logic.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:striso_core/striso_core.dart';
import 'package:striso_live/src/controller.dart' show UsbBackend;

import 'virtual.dart';

/// sv_test: the board resets (a power cycle; its flash stays); a module slot marked faulted.
const svTestReset = 3, svTestModuleFault = 8;

/// The cable pulled: USB says no Striso, and the board leaves the bus (it restarts, so its
/// console's session ends; its flash stays).
void pullCable(VirtualUsb usb) {
  usb.present = false;
  usb.board.testHook(svTestReset);
}

/// [pullCable] in a widget test: real time for the board to restart.
Future<void> unplug(WidgetTester tester, VirtualUsb usb) async {
  final g = usb.board.usbGeneration;
  pullCable(usb);
  await tester.runAsync(() async {
    final sw = Stopwatch()..start();
    while ((usb.board.usbGeneration == g || !usb.board.attached) && sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  expect(usb.board.attached, isTrue, reason: 'the virtual board restarted');
}

/// A Striso another program holds: it will not open.
class BusyTransport implements Transport {
  @override
  String get label => 'busy';
  @override
  Stream<Uint8List> get data => const Stream.empty();
  @override
  Future<UsbError> get lost => Completer<UsbError>().future;
  @override
  Future<void> open() async => throw UsbError.busy;
  @override
  Future<void> write(Uint8List bytes) async {}
  @override
  Future<void> close() async {}
}

/// The virtual board on USB, busy for the next [busy] opens.
class BusyUsb extends VirtualUsb {
  int busy = 0;
  BusyUsb(super.board);
  @override
  Transport transport() {
    if (busy > 0) {
      busy--;
      return BusyTransport();
    }
    return super.transport();
  }
}

/// The command a write is ("StcV" -> "V"), or null for anything else.
String? commandOf(Uint8List bytes) =>
    bytes.length == 4 && bytes[0] == 0x53 && bytes[1] == 0x74 && bytes[2] == 0x63 ? String.fromCharCode(bytes[3]) : null;

Uint8List linesOf(List<String> lines) => Uint8List.fromList(ascii.encode(lines.map((l) => '$l\r\n').join()));

/// A console that answers only with [answers] (command -> its lines) and is silent otherwise, as a
/// firmware that does not know a command is: an old firmware.
class ScriptedTransport implements Transport {
  final Map<String, List<String>> answers;
  final _data = StreamController<Uint8List>.broadcast(sync: true);
  final _lost = Completer<UsbError>();
  ScriptedTransport(this.answers);
  @override
  String get label => 'scripted';
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => _lost.future;
  @override
  Future<void> open() async {}
  @override
  Future<void> write(Uint8List bytes) async {
    final a = answers[commandOf(bytes)];
    if (a != null) Timer.run(() => _data.add(linesOf(a)));
  }

  @override
  Future<void> close() async {}
}

/// A Striso on USB whose console is a [ScriptedTransport].
class ScriptedUsb implements UsbBackend {
  final Map<String, List<String>> answers;
  ScriptedUsb(this.answers);
  @override
  Future<({bool present, String where})> probe() async => (present: true, where: 'scripted');
  @override
  Transport transport() => ScriptedTransport(answers);
  @override
  Future<void> dispose() async {}
}

/// The virtual board's console, but the commands in [answers] are answered with those lines
/// instead of reaching the board: a reply the firmware the board runs does not give.
class CannedTransport implements Transport {
  final Transport board;
  final Map<String, List<String>> answers;
  final _data = StreamController<Uint8List>.broadcast(sync: true);
  StreamSubscription<Uint8List>? _sub;
  CannedTransport(this.board, this.answers);
  @override
  String get label => board.label;
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => board.lost;
  @override
  Future<void> open() async {
    await board.open();
    _sub = board.data.listen(_data.add);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final a = answers[commandOf(bytes)];
    if (a == null) return board.write(bytes);
    Timer.run(() => _data.add(linesOf(a)));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await board.close();
  }
}

/// The virtual board on USB with [answers] canned (the map may change while it plays).
class CannedUsb extends VirtualUsb {
  final Map<String, List<String>> answers;
  CannedUsb(super.board, [Map<String, List<String>>? answers]) : answers = answers ?? {};
  @override
  Transport transport() => CannedTransport(super.transport(), answers);
}
