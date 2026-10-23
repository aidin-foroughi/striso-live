#!/bin/sh
# Package the macOS app after `flutter build macos --release` (run from anywhere):
#   tool/package_macos.sh [path/to/libusb-1.0.0.dylib]      (default: brew's libusb)
# Puts libusb into the bundle and signs it ad hoc (tool/bundle_libusb_macos.sh), checks that the
# app and libusb run on Apple silicon and Intel, and writes
#   dist/StrisoLive-<version>-macos.zip   the app (unzip, move to Applications)
#   dist/StrisoLive-<version>-macos.dmg   the app and an Applications link (drag to install)
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml)
[ -n "$version" ] || { echo "no version in pubspec.yaml" >&2; exit 1; }
APP="build/macos/Build/Products/Release/Striso Live.app"
[ -d "$APP" ] || { echo "no $APP: run flutter build macos --release first" >&2; exit 1; }

sh tool/bundle_libusb_macos.sh "$APP" ${1:+"$1"}

# every Mach-O in the bundle must hold both architectures
bad=0
for f in "$APP/Contents/MacOS/Striso Live" "$APP/Contents/Frameworks/libusb-1.0.0.dylib" \
         "$APP/Contents/Frameworks/App.framework/App" \
         "$APP/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"; do
  archs=$(lipo -archs "$f" 2>/dev/null || echo "missing")
  echo "$archs  ${f#"$APP/"}"
  case " $archs " in *" arm64 "*) ;; *) bad=1 ;; esac
  case " $archs " in *" x86_64 "*) ;; *) bad=1 ;; esac
done
[ "$bad" = 0 ] || { echo "not universal (arm64 + x86_64): see above" >&2; exit 1; }

mkdir -p dist
zip="dist/StrisoLive-$version-macos.zip"
dmg="dist/StrisoLive-$version-macos.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Striso Live.app"
ln -s /Applications "$stage/Applications"
# hdiutil on CI runners now and then fails with "Resource busy": retry
n=0
until hdiutil create -volname "Striso Live" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"; do
  n=$((n + 1))
  [ "$n" -lt 4 ] || { echo "hdiutil create failed" >&2; exit 1; }
  sleep 5
done
hdiutil verify "$dmg"
ls -l "$zip" "$dmg"
