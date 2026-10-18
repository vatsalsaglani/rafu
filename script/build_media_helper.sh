#!/usr/bin/env bash
# Builds Vendor/MediaRemoteAdapter (BSD-3, ungive/mediaremote-adapter at
# 73f14ab, vendored through Cider) into MediaRemoteAdapter.framework for the
# notch's system Now Playing source.
#
# usage: script/build_media_helper.sh <output-directory>
#
# Optional by design: when the Xcode command line tools (xcrun clang) are
# missing or the compile fails, this prints one line to stderr and exits 1
# without touching <output-directory>. The caller then skips staging, and
# Now Playing uses its Music/Spotify fallback. It never fails the app build.
set -uo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-directory>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Vendor/MediaRemoteAdapter"
OUTPUT_DIR="$1"
FRAMEWORK_NAME="MediaRemoteAdapter.framework"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
  echo "MediaRemote adapter skipped: xcrun clang is not available." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rafu-media.XXXXXX")" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
FRAMEWORK="$WORK_DIR/$FRAMEWORK_NAME"
mkdir -p "$FRAMEWORK/Resources"

shopt -s nullglob
SOURCES=(
  "$SOURCE_DIR"/src/adapter/*.m
  "$SOURCE_DIR"/src/private/*.m
  "$SOURCE_DIR"/src/utility/*.m
)
shopt -u nullglob
if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "MediaRemote adapter skipped: no vendored sources." >&2
  exit 1
fi

if ! xcrun clang -dynamiclib -fobjc-arc -fvisibility=default \
  -mmacosx-version-min=15.0 \
  -I "$SOURCE_DIR/include" -I "$SOURCE_DIR/src" \
  "${SOURCES[@]}" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name "@rpath/$FRAMEWORK_NAME/MediaRemoteAdapter" \
  -o "$FRAMEWORK/MediaRemoteAdapter"; then
  echo "MediaRemote adapter skipped: the framework did not compile." >&2
  exit 1
fi

cat >"$FRAMEWORK/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key>
  <string>dev.vatsalsaglani.rafu.MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
</dict>
</plist>
PLIST

# Ad-hoc sign the framework here so the enclosing app can be signed after it.
codesign --force --sign - --timestamp=none "$FRAMEWORK" >/dev/null 2>&1 || true

mkdir -p "$OUTPUT_DIR"
rm -rf "${OUTPUT_DIR:?}/$FRAMEWORK_NAME"
mv "$FRAMEWORK" "$OUTPUT_DIR/$FRAMEWORK_NAME"
