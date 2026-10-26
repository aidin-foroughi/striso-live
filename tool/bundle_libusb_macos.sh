#!/bin/sh
# Put libusb-1.0 into the macOS app bundle and sign the bundle ad hoc (unsigned for Gatekeeper).
#   tool/bundle_libusb_macos.sh "build/macos/Build/Products/Release/Striso Live.app" path/to/libusb-1.0.0.dylib
# The app loads Contents/Frameworks/libusb-1.0.0.dylib (lib/src/libusb.dart in striso_usb).
set -eu
APP="$1"
LIB="${2:-}"
if [ -z "$LIB" ]; then
  for c in /opt/homebrew/lib/libusb-1.0.0.dylib /usr/local/lib/libusb-1.0.0.dylib; do
    [ -f "$c" ] && LIB="$c" && break
  done
fi
[ -n "$LIB" ] || { echo "no libusb-1.0.0.dylib: brew install libusb, or pass its path" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -L "$LIB" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
chmod 644 "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
echo "libusb: $(lipo -archs "$APP/Contents/Frameworks/libusb-1.0.0.dylib")"
otool -L "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
# striso_audio, built into the bundle by tool/package_macos.sh, when it is there
if [ -f "$APP/Contents/Frameworks/libstriso_audio.dylib" ]; then
  codesign --force --sign - "$APP/Contents/Frameworks/libstriso_audio.dylib"
fi
codesign --force --deep --sign - "$APP"
codesign --verify --deep --verbose=2 "$APP"
