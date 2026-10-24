# miniaudio (vendored)

- Version: **0.11.25** (released 2026-03-03), tag `0.11.25`, commit
  `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` of https://github.com/mackron/miniaudio
- Files: `miniaudio.h` (two local patches, below) and `LICENSE` (public domain / MIT No Attribution, your choice).
- SHA-256:
  - `miniaudio.h` as released `ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89`,
    with the two patches `00f9aa86e3c760b24e560fad1bf55063272007ebf0be516a9f3519e767074150`
  - `LICENSE` `457f1b500e0adf6bc059edddfa78a2f62012e7c3bb43476c20e0bd23b25ba0eb`

`src/striso_audio.c` compiles the implementation (`MINIAUDIO_IMPLEMENTATION`) with only the
WASAPI, Core Audio and null backends and without the decoders, encoders, node graph and engine.
To update: download `miniaudio.h` and `LICENSE` from the new tag, update this file, run the
self-test (`striso_audio_check --selftest`, see the app's README).

## Local patch

One block in `ma_device_init_internal__wasapi`, after the exclusive-mode device format is read,
inside `#if defined(MA_WASAPI_EXCLUSIVE_CAPTURE_PREFER_S24)` (defined by `src/striso_audio.c`):
an exclusive capture stream asks for 24-bit samples in 3 bytes at the device's rate and channels
first (`IsFormatSupported`), and keeps Windows' default format for the device when that is
refused. The Striso's UAC2 function offers 24 and 16 bit, and Windows' default format may be 16.
Search for "striso_audio local patch" to find it; carry it over when updating miniaudio.

## Local patch 2: timestamps for measurements

Three blocks, each compiled only when `src/striso_audio.c` defines the hook macro (search for
"striso_audio local patch"):

- `ma_device_read__wasapi`: `IAudioCaptureClient_GetBuffer` is asked for the packet's device
  position and QPC time (instead of NULL), and `MA_CAPTURE_PACKET_HOOK(device, frames, flags,
  position, qpc)` is called with them for every buffer.
- `ma_on_input__coreaudio`: the same hook with the input time stamp's sample time and host time.
- `ma_on_output__coreaudio`: `MA_PLAYBACK_TIME_HOOK(device, frames, host time)`: when the buffer
  about to be rendered is presented.

Without the macros the code is miniaudio's own. Carry both patches over when updating.
