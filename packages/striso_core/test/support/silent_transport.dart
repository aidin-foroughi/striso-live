// A transport for the cases the real board (and the virtual one) can't show: a firmware without a
// command (it never answers it: an older StcN, StcK, StcT or Stco) and a connection that goes
// away under a pending command. It takes every write and answers nothing; [unplug] ends it like a
// cable pulled. No state and no firmware logic: the client's tests against a board run on the
// virtual board (packages/striso_virtual/test).
import 'dart:async';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';

class SilentTransport implements Transport {
  final _data = StreamController<Uint8List>.broadcast();
  final _lost = Completer<UsbError>();
  @override
  String get label => 'silent';
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => _lost.future;
  @override
  Future<void> open() async {}
  @override
  Future<void> write(Uint8List bytes) async {}
  @override
  Future<void> close() async {}

  void unplug() {
    if (!_lost.isCompleted) _lost.complete(UsbError.unplugged);
  }
}
