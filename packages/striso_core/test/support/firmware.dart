// Where the tests find the Striso firmware source (striso-control-firmware) and its tools.
//
// The firmware is its own repository. The tests that compare against it (parameter names in
// voice_*.h / fx.h, the settings map in synth_control.cpp, the config writer in tools/striso.py)
// look for it in $STRISO_FW_DIR, else in ../striso-control-firmware next to this repository,
// and skip with a message saying so when it is not there.
//
// Two layouts are understood: the flat one (voice_*.h, fx.h, synth_control.cpp at the root) and
// the split one (dsp/include/striso_dsp/ for the DSP headers, src/synth/ for synth_control.cpp);
// tools/ is at the root in both.
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

/// Where a source file may live, relative to the checkout: flat, then the split layout.
const firmwareSourceDirs = ['', 'dsp/include/striso_dsp', 'src/synth', 'src', 'dsp/include'];

/// A firmware source file by its name (voice_trumpet.h, fx.h, synth_control.cpp) in either
/// layout, or null when this checkout has none.
File? firmwareFile(String name, {Directory? dir}) {
  final d = dir ?? Directory(firmwarePath());
  for (final sub in firmwareSourceDirs) {
    final f = File(sub.isEmpty ? '${d.path}/$name' : '${d.path}/$sub/$name');
    if (f.existsSync()) return f;
  }
  return null;
}

/// The firmware checkout, when it holds the firmware source (synth_control.cpp, in either layout).
Directory? firmwareDir() {
  final d = Directory(firmwarePath());
  return firmwareFile('synth_control.cpp', dir: d) != null ? d : null;
}

/// Which layout the checkout has (for the test log).
String firmwareLayout() {
  final d = firmwareDir();
  if (d == null) return 'none';
  return File('${d.path}/synth_control.cpp').existsSync() ? 'flat' : 'split (dsp/include/striso_dsp, src/synth)';
}

/// Skip reason for tests that need the firmware source.
String get firmwareMissing =>
    'firmware source not found at ${firmwarePath()}: set STRISO_FW_DIR to a striso-control-firmware '
    'checkout, or check it out next to striso-live';
