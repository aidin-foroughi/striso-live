// The main-isolate side of the USB worker: a long-lived service (one libusb context for the app)
// and a Transport per connection for StrisoClient.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';

import 'worker.dart';

class ProbeResult {
  final bool present;
  final String where;
  final Duration took;
  const ProbeResult(this.present, this.where, this.took);
}

UsbError _usbError(String code, String message) => switch (code) {
  WireError.busy => UsbError(UsbErrorCode.busy, '${UsbError.busy.message} ($message)'),
  WireError.denied => UsbError(UsbErrorCode.denied, '${UsbError.denied.message} ($message)'),
  WireError.unplugged => UsbError.unplugged,
  WireError.noDriver => UsbError(
    UsbErrorCode.noDriver,
    'The Striso’s USB interface has no usable driver (libusb: $message). On Windows it needs WinUSB on interface 2.',
  ),
  WireError.notFound => UsbError(UsbErrorCode.other, message),
  WireError.io => UsbError(UsbErrorCode.io, 'USB error: $message'),
  _ => UsbError(UsbErrorCode.other, 'USB error: $message'),
};

class UsbService {
  final Isolate _isolate;
  final ReceivePort _port;
  final SendPort _send;
  final _pending = <int, Completer<List<Object?>>>{};
  int _nextId = 1;
  LibusbTransport? _current;
  final _log = StreamController<String>.broadcast();
  bool _disposed = false;

  UsbService._(this._isolate, this._port, this._send);

  /// libusb's log lines (where it was loaded from, load failures).
  Stream<String> get log => _log.stream;

  /// Starts the worker isolate. [libusbPath] overrides where libusb-1.0 is loaded from.
  static Future<UsbService> start({String? libusbPath}) async {
    final port = ReceivePort();
    final first = Completer<SendPort>();
    final early = <Object?>[];
    late UsbService service;
    var ready = false;
    port.listen((m) {
      if (!ready) {
        if (m is SendPort) {
          first.complete(m);
        } else {
          early.add(m);
        }
        return;
      }
      service._onMessage(m);
    });
    final iso = await Isolate.spawn(usbWorkerMain, [port.sendPort, libusbPath], debugName: 'striso-usb', errorsAreFatal: false);
    final send = await first.future;
    service = UsbService._(iso, port, send);
    ready = true;
    early.forEach(service._onMessage);
    return service;
  }

  void _onMessage(Object? m) {
    final l = m as List<Object?>;
    switch (l[0]) {
      case 'data':
        _current?._data((l[1] as TransferableTypedData).materialize().asUint8List(), l.length > 2 ? l[2] as int : 0);
      case 'lost':
        final t = _current;
        _current = null;
        t?._lost(_usbError(l[1] as String, l[2] as String));
      case 'log':
        _log.add(l[1] as String);
      default:
        final c = _pending.remove(l[1] as int);
        c?.complete(l);
    }
  }

  Future<List<Object?>> _request(List<Object?> m) {
    if (_disposed) return Future.value(['error', 0, WireError.other, 'USB service stopped']);
    final id = _nextId++;
    final c = _pending[id] = Completer<List<Object?>>();
    _send.send([m[0], id, ...m.skip(1)]);
    return c.future;
  }

  /// Is a Striso on USB? (Enumeration only: nothing is opened.)
  Future<ProbeResult> probe() async {
    final r = await _request(['probe']);
    if (r[0] != 'probe') return const ProbeResult(false, '', Duration.zero);
    return ProbeResult(r[2] as bool, r[3] as String, Duration(microseconds: r[4] as int));
  }

  /// A transport for the next connection.
  LibusbTransport transport() => LibusbTransport._(this);

  Future<void> dispose() async {
    if (_disposed) return;
    final t = _current;
    if (t != null) await t.close();
    _disposed = true;
    _send.send(['quit']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _port.close();
    await _log.close();
  }
}

/// One connection to the Striso through the USB worker.
class LibusbTransport implements Transport {
  final UsbService _service;
  final _dataController = StreamController<Uint8List>.broadcast(sync: true);
  final _lostCompleter = Completer<UsbError>();
  bool _open = false;
  String where = '';
  Duration openTook = Duration.zero;

  LibusbTransport._(this._service);

  @override
  String get label => where.isEmpty ? 'Striso (USB)' : 'Striso (USB, $where)';
  @override
  Stream<Uint8List> get data => _dataController.stream;
  @override
  Future<UsbError> get lost => _lostCompleter.future;

  /// What arrives with when it arrived in the USB worker (Timeline.now, the process's monotonic
  /// microseconds: QueryPerformanceCounter on Windows), for latency measurements.
  Stream<(Uint8List, int)> get timedData => _timedController.stream;
  final _timedController = StreamController<(Uint8List, int)>.broadcast(sync: true);

  void _data(Uint8List b, int at) {
    if (!_open) return;
    _dataController.add(b);
    if (_timedController.hasListener) _timedController.add((b, at));
  }

  /// [write], returning when the worker submitted the transfer and when it completed
  /// (Timeline.now microseconds; the OUT packet was on the bus in between).
  Future<(int, int)> writeTimed(Uint8List bytes) async {
    if (!_open) throw StateError('not connected');
    final r = await _service._request([
      'write',
      TransferableTypedData.fromList([bytes]),
    ]);
    if (r[0] != 'written') throw _usbError(r[2] as String, r[3] as String);
    return (r.length > 3 ? r[2] as int : 0, r.length > 3 ? r[3] as int : 0);
  }

  void _lost(UsbError e) {
    _open = false;
    if (!_lostCompleter.isCompleted) _lostCompleter.complete(e);
  }

  @override
  Future<void> open() async {
    if (_service._current != null) throw const UsbError(UsbErrorCode.busy, 'Striso Live already has the Striso open.');
    _service._current = this;
    final r = await _service._request(['open']);
    if (r[0] != 'opened') {
      if (identical(_service._current, this)) _service._current = null;
      throw _usbError(r[2] as String, r[3] as String);
    }
    where = r[2] as String;
    openTook = Duration(microseconds: r[3] as int);
    _open = true;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (!_open) throw StateError('not connected');
    final r = await _service._request([
      'write',
      TransferableTypedData.fromList([bytes]),
    ]);
    if (r[0] != 'written') throw _usbError(r[2] as String, r[3] as String);
  }

  @override
  Future<void> close() async {
    if (!identical(_service._current, this)) {
      _open = false;
      return;
    }
    if (_open) {
      // the board keeps streaming into its queue otherwise
      await _service._request([
        'write',
        TransferableTypedData.fromList([Cmd.streamOff()]),
      ]);
    }
    _open = false;
    await _service._request(['close']);
    if (identical(_service._current, this)) _service._current = null;
  }
}
