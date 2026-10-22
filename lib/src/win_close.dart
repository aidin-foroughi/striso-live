// Closing our own window the way the user does (WM_CLOSE), for smoke runs: the engine's
// programmatic exit crashes on shutdown in this Flutter version, the window close does not.

import 'dart:ffi';
import 'dart:io';

typedef _EnumProcN = Int32 Function(IntPtr hwnd, IntPtr lParam);

int _found = 0;
int _pid = 0;

int _enum(int hwnd, int _) {
  final out = _pidBuf;
  _getPid(hwnd, out);
  if (out.value == _pid && _isVisibleOrMin(hwnd) != 0 && _getParent(hwnd) == 0) {
    _found = hwnd;
    return 0;
  }
  return 1;
}

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _enumWindows = _user32.lookupFunction<Int32 Function(Pointer<NativeFunction<_EnumProcN>>, IntPtr), int Function(Pointer<NativeFunction<_EnumProcN>>, int)>('EnumWindows');
final _getPid = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _isVisibleOrMin = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
final _getParent = _user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetParent');
final _postMessage = _user32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('PostMessageW');
final _localAlloc = _kernel32.lookupFunction<Pointer<Uint32> Function(Uint32, IntPtr), Pointer<Uint32> Function(int, int)>('LocalAlloc');
final Pointer<Uint32> _pidBuf = _localAlloc(0x40, 4);

/// Posts WM_CLOSE to this process's top-level window; false when there is none (or not Windows).
bool closeOwnWindow() {
  if (!Platform.isWindows) return false;
  _pid = pid;
  _found = 0;
  _enumWindows(Pointer.fromFunction<_EnumProcN>(_enum, 0), 0);
  if (_found == 0) return false;
  return _postMessage(_found, 0x0010, 0, 0) != 0;
}
