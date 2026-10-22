// The USB worker isolate: owns the libusb context and the open Striso, keeps 16 bulk IN
// transfers of one packet in flight (like the web app's WebUSB reads), sends what arrives to
// the UI isolate in batches, and runs writes in order. Nothing here blocks the UI isolate.
//
// Messages from the main isolate: [op, id, ...]
//   ['probe', id]                  -> ['probe', id, present, where, micros]
//   ['open', id]                   -> ['opened', id, where, micros] | ['error', id, code, message]
//   ['write', id, bytes]           -> ['written', id] | ['error', id, code, message]
//   ['close', id]                  -> ['closed', id]
//   ['quit']
// Events: ['data', TransferableTypedData], ['lost', code, message], ['log', text]

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:striso_core/striso_core.dart' show Usb;

import 'libusb.dart';

const _readsInFlight = 16;

/// Error codes sent to the main isolate (UsbErrorCode names).
class WireError {
  static const busy = 'busy', denied = 'denied', unplugged = 'unplugged', io = 'io', noDriver = 'noDriver', notFound = 'notFound', other = 'other';
}

void usbWorkerMain(List<Object?> args) {
  final main = args[0] as SendPort;
  final explicit = args[1] as String?;
  _Worker(main, explicit).run();
}

class _Write {
  final int id;
  final Pointer<LibusbTransfer> transfer;
  _Write(this.id, this.transfer);
}

class _Worker {
  final SendPort main;
  final String? explicit;
  final port = ReceivePort();
  Libusb? usb;
  String? loadError;
  Pointer<Void> ctx = nullptr;
  Pointer<Void> handle = nullptr;
  bool claimed = false, closing = false;
  final reads = <Pointer<LibusbTransfer>>{};
  final writes = <int, _Write>{}; // transfer address -> write
  final _rx = BytesBuilder(copy: true);
  String? _lostCode;
  String _lostMessage = '';
  late final NativeCallable<Void Function(Pointer<LibusbTransfer>)> _readCb, _writeCb;
  final _tv = calloc<Timeval>();
  Completer<void>? _wake;
  final _inbox = <List<Object?>>[];
  bool _quit = false;

  _Worker(this.main, this.explicit);

  void log(String s) => main.send(['log', s]);

  void run() {
    main.send(port.sendPort);
    try {
      final u = usb = Libusb.load(explicit: explicit);
      final p = calloc<Pointer<Void>>();
      final r = u.init(p);
      if (r != LIBUSB_SUCCESS) throw StateError('libusb_init failed: ${u.errorName(r)}');
      ctx = p.value;
      calloc.free(p);
      log('libusb loaded from ${u.path}');
    } catch (e) {
      loadError = '$e';
      log(loadError!);
    }
    _readCb = NativeCallable<Void Function(Pointer<LibusbTransfer>)>.isolateLocal(_onRead);
    _writeCb = NativeCallable<Void Function(Pointer<LibusbTransfer>)>.isolateLocal(_onWrite);
    port.listen((m) {
      _inbox.add(m as List<Object?>);
      _wake?.complete();
      _wake = null;
    });
    _loop();
  }

  Future<void> _loop() async {
    while (!_quit) {
      while (_inbox.isNotEmpty) {
        _handle(_inbox.removeAt(0));
      }
      if (reads.isNotEmpty || writes.isNotEmpty) {
        _tv.ref
          ..tv_sec = 0
          ..tv_usec = 2000;
        usb!.handleEventsTimeoutCompleted(ctx, _tv, nullptr);
        _deliver();
        if (_lostCode != null && reads.isEmpty && writes.isEmpty) _finishLost();
        await Future<void>.delayed(Duration.zero);
      } else {
        _deliver();
        if (_lostCode != null) _finishLost();
        if (_inbox.isEmpty) {
          final w = _wake = Completer<void>();
          await w.future;
        }
      }
    }
    _shutdown();
  }

  void _deliver() {
    if (_rx.isEmpty) return;
    main.send([
      'data',
      TransferableTypedData.fromList([_rx.takeBytes()]),
    ]);
  }

  void _handle(List<Object?> m) {
    final op = m[0] as String;
    final id = m.length > 1 ? m[1] as int : 0;
    switch (op) {
      case 'probe':
        final sw = Stopwatch()..start();
        final found = _find(openIt: false);
        main.send(['probe', id, found.$1 != null || found.$2 != null, found.$3, sw.elapsedMicroseconds]);
      case 'open':
        _open(id);
      case 'write':
        _write(id, (m[2] as TransferableTypedData).materialize().asUint8List());
      case 'close':
        _close();
        main.send(['closed', id]);
      case 'quit':
        _close();
        _quit = true;
    }
  }

  /// Finds the Striso: (device handle if opened, error code if open failed, where).
  (Pointer<Void>?, int?, String) _find({required bool openIt}) {
    final u = usb;
    if (u == null) return (null, null, '');
    final list = calloc<Pointer<Pointer<Void>>>();
    final desc = calloc<Uint8>(18);
    final ports = calloc<Uint8>(8);
    try {
      final n = u.getDeviceList(ctx, list);
      if (n < 0) return (null, null, '');
      Pointer<Void>? opened;
      int? err;
      var where = '';
      for (var i = 0; i < n; i++) {
        final dev = list.value[i];
        if (u.getDeviceDescriptor(dev, desc) != LIBUSB_SUCCESS) continue;
        final vid = desc[8] | (desc[9] << 8), pid = desc[10] | (desc[11] << 8);
        if (vid != Usb.vendorId || pid != Usb.productId) continue;
        final np = u.getPortNumbers(dev, ports, 8);
        where =
            'bus ${u.getBusNumber(dev)} port ${[for (var k = 0; k < (np < 0 ? 0 : np); k++) ports[k]].join('.')} address ${u.getDeviceAddress(dev)}';
        if (!openIt) {
          err = 0;
          break;
        }
        final h = calloc<Pointer<Void>>();
        final r = u.open(dev, h);
        if (r == LIBUSB_SUCCESS) {
          opened = h.value;
          err = null;
        } else {
          err = r;
        }
        calloc.free(h);
        break;
      }
      u.freeDeviceList(list.value, 1);
      return (opened, err, where);
    } finally {
      calloc.free(list);
      calloc.free(desc);
      calloc.free(ports);
    }
  }

  void _fail(int id, String code, String message) => main.send(['error', id, code, message]);

  void _open(int id) {
    final u = usb;
    if (u == null) return _fail(id, WireError.noDriver, loadError ?? 'libusb is not available');
    if (handle != nullptr) return _fail(id, WireError.busy, 'already connected');
    final sw = Stopwatch()..start();
    final (h, err, where) = _find(openIt: true);
    if (h == null) {
      if (err == null) return _fail(id, WireError.notFound, 'No Striso found on USB.');
      return _fail(id, _openError(err), _openMessage(err, 'open'));
    }
    handle = h;
    if (Platform.isLinux) u.setAutoDetachKernelDriver(handle, 1);
    final r = u.claimInterface(handle, Usb.iface);
    if (r != LIBUSB_SUCCESS) {
      u.close(handle);
      handle = nullptr;
      final code = (r == LIBUSB_ERROR_BUSY || r == LIBUSB_ERROR_ACCESS) ? WireError.busy : _openError(r);
      return _fail(id, code, _openMessage(r, 'claim'));
    }
    claimed = true;
    closing = false;
    _lostCode = null;
    _rx.clear();
    for (var k = 0; k < _readsInFlight; k++) {
      final t = u.allocTransfer(0);
      final buf = calloc<Uint8>(Usb.packet);
      t.ref
        ..dev_handle = handle
        ..flags = 0
        ..endpoint = Usb.epIn
        ..type = LIBUSB_TRANSFER_TYPE_BULK
        ..timeout = 0
        ..length = Usb.packet
        ..buffer = buf
        ..callback = _readCb.nativeFunction
        ..num_iso_packets = 0;
      final s = u.submitTransfer(t);
      if (s != LIBUSB_SUCCESS) {
        calloc.free(buf);
        u.freeTransfer(t);
        _lostCode = WireError.io;
        _lostMessage = 'could not start reading: ${u.errorName(s)}';
        break;
      }
      reads.add(t);
    }
    if (_lostCode != null) {
      _close();
      return _fail(id, WireError.io, _lostMessage);
    }
    main.send(['opened', id, where, sw.elapsedMicroseconds]);
  }

  String _openError(int r) => switch (r) {
    LIBUSB_ERROR_ACCESS => Platform.isWindows ? WireError.busy : WireError.denied,
    LIBUSB_ERROR_BUSY => WireError.busy,
    LIBUSB_ERROR_NO_DEVICE => WireError.unplugged,
    LIBUSB_ERROR_NOT_SUPPORTED || LIBUSB_ERROR_NOT_FOUND => WireError.noDriver,
    _ => WireError.other,
  };

  String _openMessage(int r, String step) => '${usb!.errorName(r)} on $step';

  void _onRead(Pointer<LibusbTransfer> t) {
    final u = usb!;
    final s = t.ref.status;
    if (s == LIBUSB_TRANSFER_COMPLETED) {
      final n = t.ref.actual_length;
      if (n > 0) _rx.add(t.ref.buffer.asTypedList(n));
    }
    final again = !closing && _lostCode == null && (s == LIBUSB_TRANSFER_COMPLETED || s == LIBUSB_TRANSFER_TIMED_OUT || s == LIBUSB_TRANSFER_STALL);
    if (s == LIBUSB_TRANSFER_STALL && again) u.clearHalt(handle, Usb.epIn);
    if (again && u.submitTransfer(t) == LIBUSB_SUCCESS) return;
    if (!closing && _lostCode == null && s != LIBUSB_TRANSFER_CANCELLED) {
      _lostCode = s == LIBUSB_TRANSFER_NO_DEVICE || s == LIBUSB_TRANSFER_ERROR ? WireError.unplugged : WireError.io;
      _lostMessage = 'read ended: status $s';
      _cancelAll();
    }
    reads.remove(t);
    calloc.free(t.ref.buffer);
    u.freeTransfer(t);
  }

  void _write(int id, Uint8List bytes) {
    final u = usb;
    if (u == null || handle == nullptr || closing || _lostCode != null) return _fail(id, WireError.unplugged, 'not connected');
    final t = u.allocTransfer(0);
    final buf = calloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    t.ref
      ..dev_handle = handle
      ..flags = 0
      ..endpoint = Usb.epOut
      ..type = LIBUSB_TRANSFER_TYPE_BULK
      ..timeout = 1000
      ..length = bytes.length
      ..buffer = buf
      ..callback = _writeCb.nativeFunction
      ..num_iso_packets = 0;
    final r = u.submitTransfer(t);
    if (r != LIBUSB_SUCCESS) {
      calloc.free(buf);
      u.freeTransfer(t);
      return _fail(id, r == LIBUSB_ERROR_NO_DEVICE ? WireError.unplugged : WireError.io, 'write: ${u.errorName(r)}');
    }
    writes[t.address] = _Write(id, t);
  }

  void _onWrite(Pointer<LibusbTransfer> t) {
    final u = usb!;
    final w = writes.remove(t.address);
    final s = t.ref.status;
    if (w != null) {
      if (s == LIBUSB_TRANSFER_COMPLETED) {
        main.send(['written', w.id]);
      } else {
        _fail(w.id, s == LIBUSB_TRANSFER_NO_DEVICE ? WireError.unplugged : WireError.io, 'write ended: status $s');
      }
    }
    calloc.free(t.ref.buffer);
    u.freeTransfer(t);
  }

  void _cancelAll() {
    for (final t in reads) {
      usb!.cancelTransfer(t);
    }
    for (final w in writes.values) {
      usb!.cancelTransfer(w.transfer);
    }
  }

  void _drain() {
    final sw = Stopwatch()..start();
    while ((reads.isNotEmpty || writes.isNotEmpty) && sw.elapsedMilliseconds < 1000) {
      _tv.ref
        ..tv_sec = 0
        ..tv_usec = 10000;
      usb!.handleEventsTimeoutCompleted(ctx, _tv, nullptr);
    }
  }

  void _release() {
    final u = usb;
    if (u == null || handle == nullptr) return;
    if (claimed) u.releaseInterface(handle, Usb.iface);
    claimed = false;
    u.close(handle);
    handle = nullptr;
  }

  void _close() {
    if (handle == nullptr) return;
    closing = true;
    _cancelAll();
    _drain();
    _deliver();
    _release();
    closing = false;
    _lostCode = null;
  }

  void _finishLost() {
    final code = _lostCode!, msg = _lostMessage;
    closing = true;
    _cancelAll();
    _drain();
    _release();
    closing = false;
    _lostCode = null;
    main.send(['lost', code, msg]);
  }

  void _shutdown() {
    final u = usb;
    if (u != null && ctx != nullptr) u.exit(ctx);
    ctx = nullptr;
    _readCb.close();
    _writeCb.close();
    calloc.free(_tv);
    port.close();
  }
}
