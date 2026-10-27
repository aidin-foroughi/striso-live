// The virtual board behind striso_core's Transport, as LibusbTransport is the real one's: the same
// bytes both ways on the console (interface 2), so StrisoClient and everything above it run
// unchanged. The board must run by itself for a client (VirtualBoard.startRealtime); bytes it
// sends are polled every couple of milliseconds. A reset of the board (StcB, settings + key 67)
// takes it off the bus like a cable pulled: [lost] completes and a new transport connects after.

import 'dart:async';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';

import 'board.dart';

/// Writes [length] bytes with [writeFrom] (VirtualBoard.consoleWrite from an offset: how far it
/// got, -1 when the board is gone). A piece the board's console can't hold now is written again
/// after [retry], as the board drains; [stall] without progress is an error. False: the board is
/// gone.
Future<bool> writeAll(
  int Function(int from) writeFrom,
  int length, {
  Duration stall = const Duration(seconds: 10),
  Duration retry = const Duration(milliseconds: 2),
}) async {
  var off = 0;
  final waited = Stopwatch()..start();
  while (true) {
    final n = writeFrom(off);
    if (n < 0) return false;
    if (n >= length) return true;
    if (n > off) waited.reset();
    off = n;
    if (waited.elapsed > stall) throw StateError('the virtual board\'s console took nothing for ${stall.inSeconds} s');
    await Future<void>.delayed(retry);
  }
}

/// [bytes] from [from] in pieces of at most [piece] bytes (a multiple of 4: whole USB-MIDI packets)
/// through [write] (offset, length -> the library's answer: < 0 not attached, 0 the piece not taken
/// now, else taken whole), as sv_console_write and sv_midi_write take them. Returns how far it got
/// (bytes.length: all of it; less: the piece there was not taken, write the rest later), -1 when the
/// board is not attached.
int writePieces(List<int> bytes, int from, int Function(int off, int n) write, {int piece = 65536}) {
  var off = from;
  while (off < bytes.length) {
    final n = bytes.length - off > piece ? piece : bytes.length - off;
    final r = write(off, n);
    if (r < 0) return -1;
    if (r == 0) return off;
    off += n;
  }
  return off;
}

class VirtualBoardTransport implements Transport {
  final VirtualBoard board;
  final Duration poll;
  final _data = StreamController<Uint8List>.broadcast(sync: true);
  final _lost = Completer<UsbError>();
  Timer? _timer;
  bool _open = false;
  int _generation = -1;

  VirtualBoardTransport(this.board, {this.poll = const Duration(milliseconds: 2)});

  @override
  String get label => 'Striso (virtual board)';
  @override
  Stream<Uint8List> get data => _data.stream;
  @override
  Future<UsbError> get lost => _lost.future;
  bool get isOpen => _open;

  @override
  Future<void> open() async {
    if (_open) return;
    if (board.disposed || !board.attached) {
      throw const UsbError(UsbErrorCode.unplugged, 'The virtual board is not on USB (it is starting, or in its bootloader).');
    }
    _generation = board.usbGeneration;
    board.consoleRead(); // what it sent before we came, as a real host would never see it
    _open = true;
    _timer = Timer.periodic(poll, (_) => _pump());
  }

  void _pump() {
    if (!_open) return;
    if (board.disposed || !board.attached || board.usbGeneration != _generation) {
      _gone();
      return;
    }
    final b = board.consoleRead();
    if (b == null) {
      _gone();
    } else if (b.isNotEmpty) {
      _data.add(b);
    }
  }

  void _gone() {
    _open = false;
    _timer?.cancel();
    if (!_lost.isCompleted) _lost.complete(UsbError.unplugged);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (!_open) throw StateError('not connected');
    final ok = await writeAll((from) => board.consoleWrite(bytes, from), bytes.length);
    if (!ok) {
      _gone();
      throw UsbError.unplugged;
    }
  }

  @override
  Future<void> close() async {
    if (_open && !board.disposed && board.attached) board.consoleWrite(Cmd.streamOff());
    _open = false;
    _timer?.cancel();
  }
}
