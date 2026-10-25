# Windows MIDI Services SDK (Windows.Devices.Midi2), vendored

From Microsoft's `Windows.Devices.Midi2.0.99.92-preview.11.nupkg`
(https://github.com/microsoft/MIDI/releases/tag/inbox-preview-11, MIT licence: `LICENSE`):

- `Windows.Devices.Midi2.winmd`: the API's metadata. The build generates C++/WinRT headers from it
  with the Windows SDK's `cppwinrt.exe` (`packages/striso_audio/native/CMakeLists.txt`).
- `win-x64/Windows.Devices.Midi2.dll`, `.pri`: the SDK's implementation, app-local. It is installed
  next to the exe. C++/WinRT activates its classes from it when Windows has none registered (its
  reg-free fallback).

It talks to the Windows MIDI Service (`midisrv`), which is in-box in recent Windows 11. Without
the service, Striso Live has no MIDI 2.0 on Windows and keeps MIDI 1.0 through WinMM.

To update: take the new release's `.nupkg` (a zip), `ref/native/Windows.Devices.Midi2.winmd` and
`runtimes/win-x64/native/Windows.Devices.Midi2.{dll,pri}`.
