# striso_core

Pure-Dart core of Striso Live (the Flutter desktop app in `tools/striso_live`): the USB protocol and
stream parser, the client, the demo board, the key layout, live key state, harmony analysis,
parameters/presets/undo, the key equalizer math, the settings-mode map and the config UF2 writer
(byte-identical with `tools/striso.py`). Ported from the web app in `tools/app/js`.

    dart test

The config test compares against `tools/striso.py` through `tools/.venv` when it exists; the
settings test reads `striso-control-firmware/synth_control.cpp` when it is checked out.
