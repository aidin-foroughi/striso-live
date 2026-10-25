#!/bin/sh
# Build libstriso_audio.dylib for macOS: universal (arm64 + x86_64), macOS 10.15+, signed ad hoc.
#   sh packages/striso_audio/native/build_macos.sh [OUT_DIR] [--selftest]
# OUT_DIR defaults to packages/striso_audio/native/build/macos (where the app looks in development;
# tool/package_macos.sh passes the app bundle's Contents/Frameworks). --selftest also builds
# striso_audio_check next to it and runs the self-test (miniaudio's null backend: no real device).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build/macos"
SELFTEST=0
for a in "$@"; do
  case "$a" in
    --selftest) SELFTEST=1 ;;
    *) OUT="$a" ;;
  esac
done
mkdir -p "$OUT"
LIB="$OUT/libstriso_audio.dylib"
FLAGS="-O2 -std=gnu11 -fblocks -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -Wall -Wno-deprecated-declarations -Wno-unused-function"
clang $FLAGS -fvisibility=hidden -DSA_BUILD_DLL -I"$HERE/include" -I"$HERE/third_party/miniaudio" \
  -dynamiclib -install_name @rpath/libstriso_audio.dylib -o "$LIB" \
  "$HERE/src/striso_audio.c" "$HERE/src/sa_core.c" "$HERE/src/sa_platform.c" "$HERE/src/selftest.c" \
  "$HERE/src/striso_midi.c" "$HERE/src/selftest_midi.c" \
  -framework CoreFoundation -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework CoreMIDI -lobjc
codesign --force --sign - "$LIB"
echo "striso_audio: $(lipo -archs "$LIB")  $LIB"

if [ "$SELFTEST" = 1 ]; then
  clang $FLAGS -I"$HERE/include" -o "$OUT/striso_audio_check" "$HERE/tools/striso_audio_check.c" \
    -L"$OUT" -lstriso_audio -Wl,-rpath,"$OUT"
  codesign --force --sign - "$OUT/striso_audio_check"
  scratch=$(mktemp -d)
  "$OUT/striso_audio_check" --selftest "$scratch"
  rm -rf "$scratch"
fi
