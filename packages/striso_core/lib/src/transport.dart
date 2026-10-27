// A byte transport to the board: libusb (striso_usb), the virtual board (striso_virtual), or a
// test double.

import 'dart:async';
import 'dart:typed_data';

enum UsbErrorCode { busy, denied, unplugged, io, noDriver, other }

class UsbError implements Exception {
  final UsbErrorCode code;
  final String message;
  const UsbError(this.code, this.message);
  @override
  String toString() => message;

  static const busy = UsbError(
    UsbErrorCode.busy,
    'Device busy: another program holds the Striso. Close tools/striso.py, the browser version or another Striso Live, and connect again.',
  );
  static const denied = UsbError(
    UsbErrorCode.denied,
    'Access denied. Close tools/striso.py or any other program using the Striso; if this persists, check that WinUSB is installed for interface 2.',
  );
  static const unplugged = UsbError(UsbErrorCode.unplugged, 'The Striso was unplugged.');
}

abstract class Transport {
  String get label;

  /// Bytes from the board, as they arrive.
  Stream<Uint8List> get data;

  /// Completes once when the connection is lost (unplug, I/O error); not after [close].
  Future<UsbError> get lost;

  Future<void> open();
  Future<void> write(Uint8List bytes);

  /// Stream off, release the interface, close the device.
  Future<void> close();
}
