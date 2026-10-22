// Thin dart:ffi bindings of the part of libusb-1.0 that Striso Live uses: device list and
// descriptor, open/close, claim/release, asynchronous bulk transfers and event handling.
// Names follow libusb.h.

import 'dart:ffi';
import 'dart:io';

// error codes (libusb.h enum libusb_error)
const LIBUSB_SUCCESS = 0;
const LIBUSB_ERROR_IO = -1;
const LIBUSB_ERROR_INVALID_PARAM = -2;
const LIBUSB_ERROR_ACCESS = -3;
const LIBUSB_ERROR_NO_DEVICE = -4;
const LIBUSB_ERROR_NOT_FOUND = -5;
const LIBUSB_ERROR_BUSY = -6;
const LIBUSB_ERROR_TIMEOUT = -7;
const LIBUSB_ERROR_OVERFLOW = -8;
const LIBUSB_ERROR_PIPE = -9;
const LIBUSB_ERROR_INTERRUPTED = -10;
const LIBUSB_ERROR_NO_MEM = -11;
const LIBUSB_ERROR_NOT_SUPPORTED = -12;

// enum libusb_transfer_status
const LIBUSB_TRANSFER_COMPLETED = 0;
const LIBUSB_TRANSFER_ERROR = 1;
const LIBUSB_TRANSFER_TIMED_OUT = 2;
const LIBUSB_TRANSFER_CANCELLED = 3;
const LIBUSB_TRANSFER_STALL = 4;
const LIBUSB_TRANSFER_NO_DEVICE = 5;
const LIBUSB_TRANSFER_OVERFLOW = 6;

const LIBUSB_TRANSFER_TYPE_BULK = 2;

final class LibusbTransfer extends Struct {
  external Pointer<Void> dev_handle;
  @Uint8()
  external int flags;
  @Uint8()
  external int endpoint;
  @Uint8()
  external int type;
  @Uint32()
  external int timeout;
  @Int32()
  external int status;
  @Int32()
  external int length;
  @Int32()
  external int actual_length;
  external Pointer<NativeFunction<Void Function(Pointer<LibusbTransfer>)>> callback;
  external Pointer<Void> user_data;
  external Pointer<Uint8> buffer;
  @Int32()
  external int num_iso_packets;
}

final class Timeval extends Struct {
  @Long()
  external int tv_sec;
  @Long()
  external int tv_usec;
}

/// Where to look for the libusb shared library: next to the executable (Windows), in the app
/// bundle's Frameworks (macOS), then the system.
List<String> libusbCandidates({String? explicit}) {
  final out = <String>[];
  final env = Platform.environment['STRISO_LIBUSB'];
  if (explicit != null) out.add(explicit);
  if (env != null && env.isNotEmpty) out.add(env);
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    out.addAll(['$exeDir${sep}libusb-1.0.dll', 'libusb-1.0.dll']);
  } else if (Platform.isMacOS) {
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    out.addAll([
      '$contents/Frameworks/libusb-1.0.0.dylib',
      '$contents/Frameworks/libusb-1.0.dylib',
      '$exeDir/libusb-1.0.0.dylib',
      '/opt/homebrew/lib/libusb-1.0.0.dylib',
      '/usr/local/lib/libusb-1.0.0.dylib',
      'libusb-1.0.0.dylib',
    ]);
  } else {
    out.addAll(['$exeDir/lib/libusb-1.0.so.0', 'libusb-1.0.so.0', 'libusb-1.0.so']);
  }
  return out;
}

class Libusb {
  final DynamicLibrary lib;
  final String path;

  Libusb._(this.lib, this.path);

  /// Opens the first library that loads; throws with every path tried.
  factory Libusb.load({String? explicit}) {
    final tried = <String>[];
    for (final p in libusbCandidates(explicit: explicit)) {
      if (p.contains(Platform.pathSeparator) && !File(p).existsSync()) {
        tried.add('$p (missing)');
        continue;
      }
      try {
        return Libusb._(DynamicLibrary.open(p), p);
      } catch (e) {
        tried.add('$p ($e)');
      }
    }
    throw StateError('libusb-1.0 could not be loaded: ${tried.join('; ')}');
  }

  late final init = lib.lookupFunction<Int32 Function(Pointer<Pointer<Void>>), int Function(Pointer<Pointer<Void>>)>('libusb_init');
  late final exit = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('libusb_exit');
  late final getDeviceList = lib
      .lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>), int Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>)>(
        'libusb_get_device_list',
      );
  late final freeDeviceList = lib.lookupFunction<Void Function(Pointer<Pointer<Void>>, Int32), void Function(Pointer<Pointer<Void>>, int)>(
    'libusb_free_device_list',
  );
  // struct libusb_device_descriptor is 18 bytes; idVendor at 8, idProduct at 10
  late final getDeviceDescriptor = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>), int Function(Pointer<Void>, Pointer<Uint8>)>(
    'libusb_get_device_descriptor',
  );
  late final getBusNumber = lib.lookupFunction<Uint8 Function(Pointer<Void>), int Function(Pointer<Void>)>('libusb_get_bus_number');
  late final getDeviceAddress = lib.lookupFunction<Uint8 Function(Pointer<Void>), int Function(Pointer<Void>)>('libusb_get_device_address');
  late final getPortNumbers = lib
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32), int Function(Pointer<Void>, Pointer<Uint8>, int)>(
        'libusb_get_port_numbers',
      );
  late final open = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>), int Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
    'libusb_open',
  );
  late final close = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('libusb_close');
  late final claimInterface = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('libusb_claim_interface');
  late final releaseInterface = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>(
    'libusb_release_interface',
  );
  late final setAutoDetachKernelDriver = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>(
    'libusb_set_auto_detach_kernel_driver',
  );
  late final clearHalt = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint8), int Function(Pointer<Void>, int)>('libusb_clear_halt');
  late final allocTransfer = lib.lookupFunction<Pointer<LibusbTransfer> Function(Int32), Pointer<LibusbTransfer> Function(int)>(
    'libusb_alloc_transfer',
  );
  late final freeTransfer = lib.lookupFunction<Void Function(Pointer<LibusbTransfer>), void Function(Pointer<LibusbTransfer>)>(
    'libusb_free_transfer',
  );
  late final submitTransfer = lib.lookupFunction<Int32 Function(Pointer<LibusbTransfer>), int Function(Pointer<LibusbTransfer>)>(
    'libusb_submit_transfer',
  );
  late final cancelTransfer = lib.lookupFunction<Int32 Function(Pointer<LibusbTransfer>), int Function(Pointer<LibusbTransfer>)>(
    'libusb_cancel_transfer',
  );
  late final handleEventsTimeoutCompleted = lib
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Timeval>, Pointer<Int32>), int Function(Pointer<Void>, Pointer<Timeval>, Pointer<Int32>)>(
        'libusb_handle_events_timeout_completed',
      );
  late final _errorName = lib.lookupFunction<Pointer<Uint8> Function(Int32), Pointer<Uint8> Function(int)>('libusb_error_name');

  String errorName(int code) {
    final p = _errorName(code);
    if (p == nullptr) return 'error $code';
    final b = StringBuffer();
    for (var i = 0; i < 64 && p[i] != 0; i++) {
      b.writeCharCode(p[i]);
    }
    return b.toString();
  }
}
