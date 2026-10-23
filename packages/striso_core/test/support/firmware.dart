// Where the tests find the Striso firmware source (striso-control-firmware) and its tools.
//
// The firmware is its own repository. The tests that compare against it (parameter names in
// voice_*.h / fx.h, the settings map in synth_control.cpp, the config writer in tools/striso.py)
// look for it in $STRISO_FW_DIR, else in ../striso-control-firmware next to this repository,
// and skip with a message saying so when it is not there.
import 'dart:io';

/// The striso-live repository root: the directory holding packages/striso_core.
Directory? repoRoot() {
  for (var d = Directory.current.absolute; ; d = d.parent) {
    if (File('${d.path}/packages/striso_core/pubspec.yaml').existsSync()) return d;
    if (d.parent.path == d.path) return null;
  }
}

/// The firmware checkout that was asked for (it may not exist).
String firmwarePath() {
  final env = Platform.environment['STRISO_FW_DIR'];
  if (env != null && env.isNotEmpty) return Directory(env).absolute.path;
  final root = repoRoot() ?? Directory.current.absolute;
  return Directory('${root.path}/../striso-control-firmware').absolute.path;
}

/// The firmware checkout, when it holds the firmware source (synth_control.cpp).
Directory? firmwareDir() {
  final d = Directory(firmwarePath());
  return File('${d.path}/synth_control.cpp').existsSync() ? d : null;
}

/// Skip reason for tests that need the firmware source.
String get firmwareMissing =>
    'firmware source not found at ${firmwarePath()}: set STRISO_FW_DIR to a striso-control-firmware '
    'checkout, or check it out next to striso-live';

/// A Python that can import the firmware's tools/striso.py (pyusb, libusb_package): $STRISO_PYTHON,
/// else the firmware's tools/.venv.
String? firmwarePython() {
  final fw = firmwareDir();
  if (fw == null || !File('${fw.path}/tools/striso.py').existsSync()) return null;
  final env = Platform.environment['STRISO_PYTHON'];
  if (env != null && env.isNotEmpty) return env;
  for (final p in ['${fw.path}/tools/.venv/Scripts/python.exe', '${fw.path}/tools/.venv/bin/python']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Skip reason for tests that need tools/striso.py and its Python.
String get pythonMissing =>
    'tools/striso.py with a Python not found: needs ${firmwarePath()}/tools/striso.py and its '
    'tools/.venv (python -m venv tools/.venv && tools/.venv/.../pip install -r tools/requirements.txt), '
    'or STRISO_PYTHON; set STRISO_FW_DIR for another firmware checkout';
