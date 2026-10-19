#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="${RAFU_APP_NAME:-Rafu Lightning}"
APP_EXECUTABLE="${APP_NAME// /}"
GUI_PRODUCT="RafuApp"
CLI_PRODUCT="rafu"
HOOK_HELPER_PRODUCT="rafu-agent-events"
MIN_SYSTEM_VERSION="15.0"
# Overridable so the release workflow can stamp the branch-derived version
# into the bundle without editing this script.
VERSION="${RAFU_VERSION:-0.1.0}"

case "$APP_NAME" in
  "Rafu Lightning")
    BUNDLE_ID="dev.vatsalsaglani.rafu.lightning"
    SEAM_COLOR="#C0C6CE"
    ;;
  "Rafu")
    BUNDLE_ID="dev.vatsalsaglani.rafu"
    SEAM_COLOR="#E3A857"
    ;;
  *)
    echo "RAFU_APP_NAME must be either 'Rafu Lightning' or 'Rafu'." >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_ONLY=false
STOPS_EXISTING_APP=false

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [run|--stage|--package|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
fi

case "$MODE" in
  --stage|stage)
    STAGE_ONLY=true
    ;;
  --package|package)
    ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    STOPS_EXISTING_APP=true
    ;;
  *)
    echo "usage: $0 [run|--stage|--package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

if [[ "$STAGE_ONLY" == true ]]; then
  APP_BUNDLE="$DIST_DIR/.$APP_EXECUTABLE-stage.app"
else
  APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
fi

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_SHARED_BIN="$APP_CONTENTS/SharedSupport/bin"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_BINARY="$APP_MACOS/$APP_EXECUTABLE"
CLI_BINARY="$APP_SHARED_BIN/$CLI_PRODUCT"
HOOK_HELPER_BINARY="$APP_HELPERS/$HOOK_HELPER_PRODUCT"
MEDIA_FRAMEWORK_CACHE="$ROOT_DIR/.build/rafu-media"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="Rafu.icns"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME"

cd "$ROOT_DIR"
if [[ "$STOPS_EXISTING_APP" == true ]]; then
  pkill -x "$APP_EXECUTABLE" >/dev/null 2>&1 || true
fi

swift build --product "$GUI_PRODUCT"
swift build --product "$CLI_PRODUCT"
swift build --product "$HOOK_HELPER_PRODUCT"

BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_APP_BINARY="$BUILD_BIN_DIR/$GUI_PRODUCT"
BUILD_CLI_BINARY="$BUILD_BIN_DIR/$CLI_PRODUCT"
BUILD_HOOK_HELPER_BINARY="$BUILD_BIN_DIR/$HOOK_HELPER_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_SHARED_BIN" "$APP_HELPERS"

cp "$BUILD_APP_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
# Agent hook helper (X11). Settings > Agents copies it to Application Support
# on Connect; hooks never run it from inside the bundle.
cp "$BUILD_HOOK_HELPER_BINARY" "$HOOK_HELPER_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY" "$HOOK_HELPER_BINARY"

# System Now Playing (X11): the BSD-3 MediaRemote adapter, run by
# /usr/bin/perl. Optional: without xcrun clang the build skips it and Now
# Playing falls back to Music and Spotify. Never fails the app build.
if "$ROOT_DIR/script/build_media_helper.sh" "$MEDIA_FRAMEWORK_CACHE"; then
  cp -R "$MEDIA_FRAMEWORK_CACHE/MediaRemoteAdapter.framework" "$APP_HELPERS/"
  cp "$ROOT_DIR/Vendor/MediaRemoteAdapter/bin/mediaremote-adapter.pl" "$APP_RESOURCES/"
  cp "$ROOT_DIR/Vendor/MediaRemoteAdapter/LICENSE" "$APP_RESOURCES/MediaRemoteAdapter-LICENSE"
else
  echo "Now Playing will use the Music and Spotify fallback in this build." >&2
fi

if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_RESOURCES/"
fi

# Older SwiftPM emits flat bundles whose accessor searches the app root.
# Swift 6.4's Swift Build backend emits macOS bundles and searches Resources.
# Preserve each generated bundle layout and include dependency resources.
RESOURCE_BUNDLE_NAME="Rafu_${GUI_PRODUCT}.bundle"
for resource_bundle_name in "$RESOURCE_BUNDLE_NAME" "SwiftTerm_SwiftTerm.bundle"; do
  source_bundle="$BUILD_BIN_DIR/$resource_bundle_name"
  if [[ -d "$source_bundle/Contents/Resources" ]]; then
    cp -R "$source_bundle" "$APP_RESOURCES/"
  elif [[ -d "$source_bundle" ]]; then
    cp -R "$source_bundle" "$APP_BUNDLE/"
  fi
done
if [[ -d "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME/Contents/Resources" ]]; then
  GRAMMAR_RESOURCE_ROOT="$APP_RESOURCES/$RESOURCE_BUNDLE_NAME/Contents/Resources"
else
  GRAMMAR_RESOURCE_ROOT="$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
fi

"$ROOT_DIR/script/generate_app_icon.sh" "$APP_ICON" "$SEAM_COLOR"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE</string>
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
  <key>NSAppleEventsUsageDescription</key>
  <string>Rafu asks Music and Spotify what is playing, and sends them play, pause, next, and previous, only when you use Now Playing in the notch.</string>
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
    <dict>
      <key>CFBundleTypeName</key>
      <string>Rafu Ensemble</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>dev.rafu.ensemble</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Rafu Workspace</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>dev.rafu.workspace</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.vatsalsaglani.rafu.editor-drag-v2</string>
      <key>UTTypeDescription</key>
      <string>Rafu editor drag item</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.item</string>
      </array>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.rafu.ensemble</string>
      <key>UTTypeDescription</key>
      <string>Rafu Ensemble</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.json</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>rafuensemble</string>
        </array>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.rafu.workspace</string>
      <key>UTTypeDescription</key>
      <string>Rafu Workspace</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.json</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>rafuworkspace</string>
        </array>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.vatsalsaglani.rafu.ensemble-drag-v2</string>
      <key>UTTypeDescription</key>
      <string>Rafu Ensemble drag item</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.item</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Best-effort ad-hoc sign the staged bundle. Without a bundle identity,
# macOS's `UNUserNotificationCenter.current()` (terminal-manager.md T-E's
# attention notifications) is known to fail or trap
# ("bundleProxyForCurrentProcess is nil") against an unsigned app. `--sign -`
# needs no Developer ID/keychain entry, so this stays CI/local-safe.
#
# NOT fatal on failure: with older SwiftPM, the vendored tree-sitter resource bundle
# ("$RESOURCE_BUNDLE_NAME") sits at the .app TOP LEVEL, beside
# Contents (see Sources/RafuApp/Resources/Grammars/README.md) — SwiftPM's
# flat resource-bundle layout requires this for `Bundle.module` to resolve
# it, both under `swift test`/`swift run` and here. `codesign` treats a
# loose top-level directory as "unsealed contents present in the bundle
# root" and exits non-zero even under `--force`/`--deep`; this is a known,
# accepted limitation, not a build failure — every other verification step
# below (build, resources, launch) must still pass regardless of whether
# this signing step fully seals the resource bundle.
# Nested code is signed first so the bundle signature can seal it.
codesign --force --sign - --timestamp=none "$HOOK_HELPER_BINARY"
if [[ -d "$APP_HELPERS/MediaRemoteAdapter.framework" ]]; then
  codesign --force --sign - --timestamp=none "$APP_HELPERS/MediaRemoteAdapter.framework"
fi
if [[ -d "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME" || -d "$APP_BUNDLE/SwiftTerm_SwiftTerm.bundle" ]]; then
  codesign --force --sign - --timestamp=none "$APP_BUNDLE" || true
else
  codesign --force --sign - --timestamp=none "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

plutil -lint "$INFO_PLIST" >/dev/null
test -x "$APP_BINARY"
test -x "$CLI_BINARY"
test -x "$HOOK_HELPER_BINARY"
test -s "$APP_ICON"
test "$(plutil -extract CFBundleIconFile raw "$INFO_PLIST")" = "$APP_ICON_NAME"
# Keep the Info.plist-declared drag UTI identifier in lockstep with
# `UTType.rafuEditorDrag` in EditorDragAndDrop.swift — a mismatch silently
# breaks the SwiftUI drag pasteboard bridge (see
# docs/references/drag-and-drop-custom-uttype.md). Both private drag types
# conform to public.item, NOT public.data: SwiftUI writes a public.data drag
# type as a file promise.
test "$(plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw "$INFO_PLIST")" = "dev.vatsalsaglani.rafu.editor-drag-v2"
test "$(plutil -extract UTExportedTypeDeclarations.0.UTTypeConformsTo.0 raw "$INFO_PLIST")" = "public.item"
# Keep the Ensemble file type in lockstep with `UTType.rafuEnsemble` and
# `CanvasEnsembleFile.typeIdentifier` (CanvasEnsembleFileActions.swift).
test "$(plutil -extract UTExportedTypeDeclarations.1.UTTypeIdentifier raw "$INFO_PLIST")" = "dev.rafu.ensemble"
# Keep the saved-workspace file type in lockstep with `UTType.rafuWorkspace`
# and `RafuWorkspaceFile.typeIdentifier` (WorkspaceFileActions.swift).
test "$(plutil -extract UTExportedTypeDeclarations.2.UTTypeIdentifier raw "$INFO_PLIST")" = "dev.rafu.workspace"
# Keep the Ensemble drag type (Agent History row to board) in lockstep with
# `UTType.rafuEnsembleDrag` in CanvasBoardDragPayload.swift. Like the editor
# drag type, it must be declared (or the drag bridge drops it) and conform to
# public.item (not public.data, which SwiftUI turns into a file promise).
test "$(plutil -extract UTExportedTypeDeclarations.3.UTTypeIdentifier raw "$INFO_PLIST")" = "dev.vatsalsaglani.rafu.ensemble-drag-v2"
test "$(plutil -extract UTExportedTypeDeclarations.3.UTTypeConformsTo.0 raw "$INFO_PLIST")" = "public.item"
test -f "$APP_RESOURCES/Themes/indigo.json"
test -f "$APP_RESOURCES/Themes/khadi.json"
test -f "$APP_RESOURCES/Themes/dracula.json"
test -f "$APP_RESOURCES/Themes/notion-light.json"
test -f "$APP_RESOURCES/Themes/notion-dark.json"
test -f "$APP_RESOURCES/Themes/github-light.json"
test -f "$APP_RESOURCES/Themes/github-dark.json"
# Verify the grammar in the resource layout emitted by the active backend.
test -d "$GRAMMAR_RESOURCE_ROOT"
test -f "$GRAMMAR_RESOURCE_ROOT/Grammars/Swift/highlights.scm"
test -f "$APP_RESOURCES/AppIcon/rafu-icon-seam.svg"
test -f "$APP_RESOURCES/FileIcons/claude.svg"
test -f "$APP_RESOURCES/FileIcons/codex.svg"
test -f "$APP_RESOURCES/FileIcons/gemini.svg"
test -f "$APP_RESOURCES/FileIcons/agent-claude-code.svg" && test -f "$APP_RESOURCES/FileIcons/agent-codex.svg"
test -f "$APP_RESOURCES/FileIcons/agent-opencode.svg" && test -f "$APP_RESOURCES/FileIcons/agent-cline.svg"
test -f "$APP_RESOURCES/FileIcons/agent-kimi.svg" && test -f "$APP_RESOURCES/FileIcons/agent-gemini.svg"
test -f "$APP_RESOURCES/FileIcons/agent-cursor.svg"
# First-launch onboarding ("The Unfolding") — stills for both grades.
# Video and the score were both cut from the experience (2026-07-27):
# stills + motion design only.
for grade in indigo khadi; do
  for shot in V0-knot V1-loom V2-bobbins V3-resolve I1-native I2-private I3-quiet; do
    test -f "$APP_RESOURCES/Onboarding/$grade/$shot.jpg"
  done
done
"$CLI_BINARY" --version >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    rm -rf "$APP_BUNDLE"
    ;;
  --package|package)
    # Packaging stages and verifies without stopping or launching either app.
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
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate \
      'subsystem BEGINSWITH "dev.vatsalsaglani.rafu"'
    ;;
  --verify|verify)
    open_app
    for _ in {1..30}; do
      if pgrep -x "$APP_EXECUTABLE" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "$APP_EXECUTABLE did not remain running after launch." >&2
    exit 1
    ;;
esac
