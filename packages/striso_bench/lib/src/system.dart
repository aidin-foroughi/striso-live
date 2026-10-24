// What the operating system says about the Striso: its USB functions and the drivers bound to
// them (Windows: PnP through PowerShell's Get-PnpDevice, read only), its MIDI port (Windows: winmm
// through dart:ffi; macOS: system_profiler), its audio input (the audio library's device list).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows: every present device node of VID F055 / PID 57C0 with its service (driver).
Future<List<Map<String, String>>> strisoPnp() async {
  if (!Platform.isWindows) return const [];
  const script = r"Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_F055&PID_57C0*' -or $_.InstanceId -like 'SWD\MMDEVAPI*' -and $_.FriendlyName -like '*Striso*' } | ForEach-Object { $s = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data; [pscustomobject]@{ id = $_.InstanceId; name = $_.FriendlyName; class = $_.Class; status = $_.Status; service = $s } } | ConvertTo-Json -Compress";
  try {
    final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]).timeout(const Duration(seconds: 30));
    final out = (r.stdout as String).trim();
    if (out.isEmpty) return const [];
    final j = jsonDecode(out);
    final list = j is List ? j : [j];
    return [
      for (final e in list)
        if (e is Map) {for (final k in ['id', 'name', 'class', 'status', 'service']) k: '${e[k] ?? ''}'},
    ];
  } catch (e) {
    return [
      {'error': '$e'},
    ];
  }
}

/// The driver bound to the Striso's audio function (interface 3: MI_03), e.g. usbaudio2.
String? audioDriverOf(List<Map<String, String>> pnp) =>
    pnp.where((d) => (d['id'] ?? '').toUpperCase().contains('&MI_03')).map((d) => d['service']).whereType<String>().firstOrNull;

/// The driver bound to the vendor interface (2), WinUSB for the console.
String? consoleDriverOf(List<Map<String, String>> pnp) =>
    pnp.where((d) => (d['id'] ?? '').toUpperCase().contains('&MI_02')).map((d) => d['service']).whereType<String>().firstOrNull;

final class _MidiInCapsW extends Struct {
  @Uint16()
  external int wMid;
  @Uint16()
  external int wPid;
  @Uint32()
  external int vDriverVersion;
  @Array(32)
  external Array<Uint16> szPname;
  @Uint32()
  external int dwSupport;
}

/// The MIDI inputs (Windows: winmm; macOS: system_profiler's USB tree is no MIDI list, so the
/// Core MIDI names are not read: an empty list means "not looked up").
List<String> midiInputs() {
  if (!Platform.isWindows) return const [];
  final winmm = DynamicLibrary.open('winmm.dll');
  final count = winmm.lookupFunction<Uint32 Function(), int Function()>('midiInGetNumDevs');
  final caps = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiInCapsW>, Uint32), int Function(int, Pointer<_MidiInCapsW>, int)>('midiInGetDevCapsW');
  final p = calloc<_MidiInCapsW>();
  final out = <String>[];
  try {
    for (var i = 0; i < count(); i++) {
      if (caps(i, p, sizeOf<_MidiInCapsW>()) != 0) continue;
      final cs = <int>[];
      for (var k = 0; k < 32 && p.ref.szPname[k] != 0; k++) {
        cs.add(p.ref.szPname[k]);
      }
      out.add(String.fromCharCodes(cs));
    }
  } finally {
    calloc.free(p);
  }
  return out;
}
