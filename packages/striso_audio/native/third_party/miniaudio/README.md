# miniaudio (vendored)

- Version: **0.11.25** (released 2026-03-03), tag `0.11.25`, commit
  `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` of https://github.com/mackron/miniaudio
- Files: `miniaudio.h` (unmodified) and `LICENSE` (public domain / MIT No Attribution, your choice).
- SHA-256:
  - `miniaudio.h` `ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89`
  - `LICENSE` `457f1b500e0adf6bc059edddfa78a2f62012e7c3bb43476c20e0bd23b25ba0eb`

`src/striso_audio.c` compiles the implementation (`MINIAUDIO_IMPLEMENTATION`) with only the
WASAPI, Core Audio and null backends and without the decoders, encoders, node graph and engine.
To update: download `miniaudio.h` and `LICENSE` from the new tag, update this file, run the
self-test (`striso_audio_check --selftest`, see the app's README).
