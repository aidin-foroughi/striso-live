# striso_core

Pure-Dart core of Striso Live (the Flutter desktop app at the root of this repository): the USB
protocol and stream parser, the client, the key layout, live key state, harmony analysis,
parameters/presets/undo, the key equalizer math, the settings-mode map and Save to Striso's copy of
the firmware's config (Stcc) to the update drive. No board in here: the client's tests
against a board run on the virtual one (the firmware's own code) in `packages/striso_virtual`.

    dart test

The parser tests read the firmware's own replies (`test/fixtures/`), recorded from the virtual
board by `packages/striso_virtual/tool/record_fixtures.dart`; each file names its firmware.

Some tests compare with the firmware (striso-control-firmware): the hero knob names with its
`voice_*.h` and `fx.h`, and the settings map with `synth_control.cpp`. They look for the
checkout in `$STRISO_FW_DIR`, else in `../striso-control-firmware` next to the striso-live
repository (`test/support/firmware.dart`), and skip with a message when it is not there.
