#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Rafu"
GUI_PRODUCT="RafuApp"
CLI_PRODUCT="rafu"
BUNDLE_ID="dev.vatsalsaglani.rafu"
MIN_SYSTEM_VERSION="15.0"
# Overridable so the release workflow can stamp the branch-derived version
# into the bundle without editing this script.
VERSION="${RAFU_VERSION:-0.1.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_ONLY=false

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [run|--stage|--package|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
fi

case "$MODE" in
  --stage|stage)
    STAGE_ONLY=true
    ;;
  run|--package|package|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--stage|--package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

if [[ "$STAGE_ONLY" == true ]]; then
  APP_BUNDLE="$DIST_DIR/.Rafu-stage.app"
else
  APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
fi

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_SHARED_BIN="$APP_CONTENTS/SharedSupport/bin"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$APP_SHARED_BIN/$CLI_PRODUCT"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="Rafu.icns"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME"

cd "$ROOT_DIR"
if [[ "$STAGE_ONLY" == false ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build --product "$GUI_PRODUCT"
swift build --product "$CLI_PRODUCT"

BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_APP_BINARY="$BUILD_BIN_DIR/$GUI_PRODUCT"
BUILD_CLI_BINARY="$BUILD_BIN_DIR/$CLI_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_SHARED_BIN"

cp "$BUILD_APP_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY"

if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_RESOURCES/"
fi

# Stage the SwiftPM resource bundle (vendored tree-sitter highlights.scm) at
# the .app TOP LEVEL — beside Contents, NOT inside Contents/Resources — which
# is where `Bundle.module` resolves it via `Bundle.main.bundleURL`. SPM emits a
# FLAT bundle, so SwiftTreeSitter's own bundle resolver never finds these; we
# load them directly with `Bundle.module`. See
# Sources/RafuApp/Resources/Grammars/README.md.
# SPM names the bundle "<PackageName>_<TargetName>.bundle" — here Rafu_RafuApp.
RESOURCE_BUNDLE_NAME="Rafu_${GUI_PRODUCT}.bundle"
if [[ -d "$BUILD_BIN_DIR/$RESOURCE_BUNDLE_NAME" ]]; then
  rm -rf "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
  cp -R "$BUILD_BIN_DIR/$RESOURCE_BUNDLE_NAME" "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
fi

"$ROOT_DIR/script/generate_app_icon.sh" "$APP_ICON"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Folder</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.vatsalsaglani.rafu.editor-drag</string>
      <key>UTTypeDescription</key>
      <string>Rafu editor drag item</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
test -x "$APP_BINARY"
test -x "$CLI_BINARY"
test -s "$APP_ICON"
test "$(plutil -extract CFBundleIconFile raw "$INFO_PLIST")" = "$APP_ICON_NAME"
# Keep the Info.plist-declared drag UTI identifier in lockstep with
# `UTType.rafuEditorDrag` in EditorDragAndDrop.swift — a mismatch silently
# breaks the SwiftUI drag pasteboard bridge (see
# docs/references/drag-and-drop-custom-uttype.md).
test "$(plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw "$INFO_PLIST")" = "dev.vatsalsaglani.rafu.editor-drag"
test -f "$APP_RESOURCES/Themes/indigo.json"
test -f "$APP_RESOURCES/Themes/khadi.json"
test -f "$APP_RESOURCES/Themes/dracula.json"
test -f "$APP_RESOURCES/Themes/notion-light.json"
test -f "$APP_RESOURCES/Themes/notion-dark.json"
test -f "$APP_RESOURCES/Themes/github-light.json"
test -f "$APP_RESOURCES/Themes/github-dark.json"
# The vendored tree-sitter query bundle must land at the .app top level (where
# Bundle.module resolves it) with its grammar subdirectories intact.
test -d "$APP_BUNDLE/Rafu_${GUI_PRODUCT}.bundle"
test -f "$APP_BUNDLE/Rafu_${GUI_PRODUCT}.bundle/Grammars/Swift/highlights.scm"
test -f "$APP_RESOURCES/AppIcon/rafu-icon-seam.svg"
test -f "$APP_RESOURCES/FileIcons/claude.svg"
test -f "$APP_RESOURCES/FileIcons/codex.svg"
test -f "$APP_RESOURCES/FileIcons/gemini.svg"
"$CLI_BINARY" --version >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    rm -rf "$APP_BUNDLE"
    ;;
  --package|package)
    # CI packaging: stage dist/Rafu.app, verify, never launch, keep the bundle.
    echo "Packaged $APP_BUNDLE (version $VERSION)"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..30}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "$APP_NAME did not remain running after launch." >&2
    exit 1
    ;;
esac
