#!/usr/bin/env bash
# Install or update Striso Live on macOS (Apple silicon and Intel). No sudo, no admin password:
#
#   curl -fsSL https://raw.githubusercontent.com/aidin-foroughi/striso-live/main/install-mac.sh | bash
#
# Downloads the latest release's StrisoLive-macos.zip, checks it against its published SHA-256,
# quits a running Striso Live, replaces "Striso Live.app" in /Applications (or ~/Applications when
# /Applications is not writable without sudo), clears the download quarantine (the app is not
# notarized) and opens it. Run it again to update.
#
# Options (environment variables, e.g. curl ... | STRISO_LIVE_VERSION=v1.3.0 bash):
#   STRISO_LIVE_VERSION=v1.3.0   a release tag (default: the latest release)
#   STRISO_LIVE_DIR=<folder>     install into this folder
#   STRISO_LIVE_NO_OPEN=1        do not open the app afterwards
#   STRISO_LIVE_DRY_RUN=1        only print what would be downloaded and where it would go
#   STRISO_LIVE_REPO=<owner/repo>, STRISO_LIVE_BASE_URL=<url>   download from elsewhere (forks, tests)
set -euo pipefail

main() {
  local repo="${STRISO_LIVE_REPO:-aidin-foroughi/striso-live}"
  local asset="StrisoLive-macos.zip"
  local app_name="Striso Live.app"
  local base
  if [ -n "${STRISO_LIVE_BASE_URL:-}" ]; then
    base="${STRISO_LIVE_BASE_URL%/}"
  elif [ -n "${STRISO_LIVE_VERSION:-}" ]; then
    base="https://github.com/$repo/releases/download/$STRISO_LIVE_VERSION"
  else
    base="https://github.com/$repo/releases/latest/download"
  fi
  local zip_url="$base/$asset"
  local proto="=https"   # an explicit STRISO_LIVE_BASE_URL (a mirror, a local test server) may be http
  [ -z "${STRISO_LIVE_BASE_URL:-}" ] || proto="=http,https"
  local sum_url="$base/$asset.sha256"

  local dest
  dest="$(pick_dir "$app_name")"
  local target="$dest/$app_name"

  say "Striso Live installer"
  say "download:    $zip_url"
  say "checksum:    $sum_url"
  say "install to:  $target"
  if [ -n "${STRISO_LIVE_DRY_RUN:-}" ]; then
    say "dry run: nothing downloaded or changed"
    return 0
  fi
  [ "$(uname -s)" = Darwin ] || die "this installer is for macOS (on Windows use install-windows.ps1)"
  for tool in curl shasum unzip ditto xattr; do
    command -v "$tool" > /dev/null 2>&1 || die "missing $tool"
  done

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/striso-live.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: tmp is local
  trap "rm -rf '$tmp'" EXIT

  say "downloading $asset"
  curl -fL --proto "$proto" --tlsv1.2 --retry 3 --progress-bar -o "$tmp/$asset" "$zip_url" \
    || die "download failed: $zip_url"
  [ -s "$tmp/$asset" ] || die "the download is empty: $zip_url"

  say "checking the download"
  local want got
  want="$(curl -fsSL --proto "$proto" --tlsv1.2 --retry 3 "$sum_url" | awk '{print tolower($1); exit}')" \
    || die "could not get the checksum: $sum_url"
  case "$want" in
    *[!0-9a-f]* | "") die "the checksum file is not a SHA-256: $sum_url" ;;
  esac
  [ "${#want}" -eq 64 ] || die "the checksum file is not a SHA-256: $sum_url"
  got="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
  [ "$got" = "$want" ] || die "checksum mismatch (expected $want, got $got): download again"
  unzip -tq "$tmp/$asset" > /dev/null || die "the download is not a valid zip"

  ditto -x -k "$tmp/$asset" "$tmp/x"
  [ -x "$tmp/x/$app_name/Contents/MacOS/Striso Live" ] || die "the zip does not hold $app_name"

  quit_running

  say "installing"
  mkdir -p "$dest"
  local staging="$dest/.$app_name.installing"
  rm -rf "$staging"
  ditto "$tmp/x/$app_name" "$staging"
  if [ -e "$target" ]; then
    rm -rf "$target" || die "could not remove the old $target"
  fi
  mv "$staging" "$target"
  xattr -dr com.apple.quarantine "$target" 2> /dev/null || true

  local version
  version="$(/usr/bin/defaults read "$target/Contents/Info" CFBundleShortVersionString 2> /dev/null || echo "?")"
  say "installed Striso Live $version in $target"
  if [ "$target" != "/Applications/$app_name" ] && [ -e "/Applications/$app_name" ]; then
    say "note: an older copy is still in /Applications (not writable without sudo); remove it in the Finder"
  fi
  if [ -z "${STRISO_LIVE_NO_OPEN:-}" ]; then
    open "$target"
  fi
}

say() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# /Applications when it is writable without sudo (and so is an existing copy there), else
# ~/Applications; an existing copy in ~/Applications is updated where it is.
pick_dir() {
  local app_name="$1"
  if [ -n "${STRISO_LIVE_DIR:-}" ]; then
    printf '%s\n' "${STRISO_LIVE_DIR%/}"
    return
  fi
  local user_dir="$HOME/Applications"
  if [ -e "$user_dir/$app_name" ] && [ ! -e "/Applications/$app_name" ]; then
    printf '%s\n' "$user_dir"
    return
  fi
  if [ -w /Applications ] && { [ ! -e "/Applications/$app_name" ] || [ -w "/Applications/$app_name" ]; }; then
    printf '%s\n' /Applications
  else
    printf '%s\n' "$user_dir"
  fi
}

quit_running() {
  pgrep -xq "Striso Live" || return 0
  say "quitting the running Striso Live"
  osascript -e 'tell application id "org.striso.strisoLive" to quit' > /dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq "Striso Live" || return 0
    sleep 1
  done
  pkill -x "Striso Live" || true
  sleep 1
}

main "$@"
