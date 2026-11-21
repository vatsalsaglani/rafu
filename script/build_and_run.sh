#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="${RAFU_APP_NAME:-Rafu Lightning}"
APP_EXECUTABLE="${APP_NAME// /}"
GUI_PRODUCT="RafuApp"
CLI_PRODUCT="rafu"
HOOK_HELPER_PRODUCT="rafu-agent-events"
# SPIKE: WidgetKit extension executable, wrapped into an .appex below.
WIDGET_PRODUCT="RafuWidgets"
MIN_SYSTEM_VERSION="15.0"
# Overridable so the release workflow can stamp the branch-derived version
# into the bundle without editing this script.
VERSION="${RAFU_VERSION:-0.1.0}"
# Code-signing identity for the staged bundle. Default is ad-hoc ("-"), which
# needs no certificate and is what CI uses. Set RAFU_SIGN_IDENTITY (for
# example "Apple Development: Name (TEAMID)") to sign the widget extension
# and the app with a real identity so the widget gallery lists the widget.
# List usable identities with `security find-identity -v -p codesigning`.
SIGN_IDENTITY="${RAFU_SIGN_IDENTITY:--}"
# Optional: search only this keychain for the identity (a private keychain).
CODESIGN_KEYCHAIN_ARGS=()
if [[ -n "${RAFU_SIGN_KEYCHAIN:-}" ]]; then
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$RAFU_SIGN_KEYCHAIN")
fi

case "$APP_NAME" in
  "Rafu Lightning")
    BUNDLE_ID="dev.vatsalsaglani.rafu.lightning"
    SEAM_COLOR="#C0C6CE"
    # Widget link scheme. Keep in lockstep with `RafuDeepLink` in
    # Sources/RafuWidgetShared/RafuDeepLink.swift.
    URL_SCHEME="rafu-lightning"
    ;;
  "Rafu")
    BUNDLE_ID="dev.vatsalsaglani.rafu"
    SEAM_COLOR="#E3A857"
    URL_SCHEME="rafu"
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

# Stamp the selected SDK into every binary (LC_BUILD_VERSION `sdk`). SwiftPM's
# Swift Build backend would otherwise record the deployment target there, and
# the system would treat Rafu as linked against that older SDK. The minimum OS
# stays MIN_SYSTEM_VERSION (keep it equal to `.macOS(.v15)` in Package.swift;
# the stamp check below fails on a mismatch). See script/sdk_link_flags.sh.
read -ra SDK_LINK_FLAGS <<<"$("$ROOT_DIR/script/sdk_link_flags.sh" "$MIN_SYSTEM_VERSION")"

swift build --product "$GUI_PRODUCT" "${SDK_LINK_FLAGS[@]}"
swift build --product "$CLI_PRODUCT" "${SDK_LINK_FLAGS[@]}"
swift build --product "$HOOK_HELPER_PRODUCT" "${SDK_LINK_FLAGS[@]}"
swift build --product "$WIDGET_PRODUCT" "${SDK_LINK_FLAGS[@]}"

BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_APP_BINARY="$BUILD_BIN_DIR/$GUI_PRODUCT"
BUILD_CLI_BINARY="$BUILD_BIN_DIR/$CLI_PRODUCT"
BUILD_HOOK_HELPER_BINARY="$BUILD_BIN_DIR/$HOOK_HELPER_PRODUCT"
BUILD_WIDGET_BINARY="$BUILD_BIN_DIR/$WIDGET_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_SHARED_BIN" "$APP_HELPERS"

cp "$BUILD_APP_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
# Agent hook helper (X11). Settings > Agents copies it to Application Support
# on Connect; hooks never run it from inside the bundle.
cp "$BUILD_HOOK_HELPER_BINARY" "$HOOK_HELPER_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY" "$HOOK_HELPER_BINARY"

# SPIKE: WidgetKit extension. SwiftPM cannot emit an .appex, so the script
# assembles one around the RafuWidgets executable (its @main WidgetBundle
# provides the entry point; no -e _NSExtensionMain is needed). An app
# extension must be sandboxed. It reads the app's snapshot through a
# read-only home-relative temporary exception, scoped to this variant's
# own Application Support folder. Signed ad-hoc before the app bundle.
WIDGET_APPEX="$APP_CONTENTS/PlugIns/$WIDGET_PRODUCT.appex"
WIDGET_BUNDLE_ID="$BUNDLE_ID.widgets"
WIDGET_ENTITLEMENTS="$ROOT_DIR/.build/rafu-widgets.entitlements"
mkdir -p "$WIDGET_APPEX/Contents/MacOS"
cp "$BUILD_WIDGET_BINARY" "$WIDGET_APPEX/Contents/MacOS/$WIDGET_PRODUCT"
chmod +x "$WIDGET_APPEX/Contents/MacOS/$WIDGET_PRODUCT"
cat >"$WIDGET_APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$WIDGET_PRODUCT</string>
  <key>CFBundleIdentifier</key>
  <string>$WIDGET_BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$WIDGET_PRODUCT</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST
cat >"$WIDGET_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array>
    <string>/Library/Application Support/$APP_NAME/Widgets/</string>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$WIDGET_APPEX/Contents/Info.plist" "$WIDGET_ENTITLEMENTS" >/dev/null

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

# SwiftPM resource bundles always go in Contents/Resources, for every
# toolchain. A loose bundle at the .app root cannot be sealed by codesign
# ("unsealed contents present in the bundle root"), and an unsealed app has an
# invalid signature: macOS cannot keep a Keychain "Always Allow" grant for it
# (docs/references/claude-keychain-usage-credential.md). Older SwiftPM emits a
# flat bundle whose generated accessor looks only at the app root, so Rafu's own
# code finds its bundle through `Bundle.rafuResources`
# (Sources/RafuApp/Support/RafuResourceBundle.swift), which checks
# Contents/Resources first. Swift 6.4's Swift Build backend emits a macOS
# bundle (Contents/Resources inside it) whose accessor already searches
# Contents/Resources. SwiftTerm's bundle holds only its optional Metal shader;
# Rafu never enables that renderer, so nothing evaluates its accessor.
RESOURCE_BUNDLE_NAME="Rafu_${GUI_PRODUCT}.bundle"
for resource_bundle_name in "$RESOURCE_BUNDLE_NAME" "SwiftTerm_SwiftTerm.bundle"; do
  source_bundle="$BUILD_BIN_DIR/$resource_bundle_name"
  if [[ -d "$source_bundle" ]]; then
    cp -R "$source_bundle" "$APP_RESOURCES/"
  fi
done
if [[ -d "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME/Contents/Resources" ]]; then
  GRAMMAR_RESOURCE_ROOT="$APP_RESOURCES/$RESOURCE_BUNDLE_NAME/Contents/Resources"
else
  GRAMMAR_RESOURCE_ROOT="$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
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
  <key>NSMicrophoneUsageDescription</key>
  <string>Rafu listens only while you hold ⌃⌥Space or keep a voice session open. Audio goes to OpenAI GPT-Live with your own API key.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Rafu asks Music and Spotify what is playing, and sends them play, pause, next, and previous, only when you use Now Playing in the notch.</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.usage-link</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$URL_SCHEME</string>
      </array>
    </dict>
  </array>
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

# Sign the staged bundle (ad-hoc unless RAFU_SIGN_IDENTITY is set). Without a bundle identity,
# macOS's `UNUserNotificationCenter.current()` (terminal-manager.md T-E's
# attention notifications) is known to fail or trap
# ("bundleProxyForCurrentProcess is nil") against an unsigned app. `--sign -`
# needs no Developer ID/keychain entry, so this stays CI/local-safe.
#
# The result MUST verify, for every variant. The release app (APP_NAME "Rafu")
# once shipped with an invalid signature because this step ended in `|| true`:
# resource bundles at the .app root made codesign fail and nothing noticed;
# that app then showed "credential access was denied" for Claude usage. Resource bundles
# now sit in Contents/Resources (see above), so signing seals the whole
# bundle, and a failure here stops the script with a clear message.
# Nested code is signed first so the bundle signature can seal it.
sign_item() {
  # `${arr[@]+...}` keeps an empty array safe under `set -u` on bash 3.2.
  codesign --force --sign "$SIGN_IDENTITY" \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} --timestamp=none "$@"
}
sign_item "$HOOK_HELPER_BINARY"
sign_item --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_APPEX"
if [[ -d "$APP_HELPERS/MediaRemoteAdapter.framework" ]]; then
  sign_item "$APP_HELPERS/MediaRemoteAdapter.framework"
fi
sign_item "$APP_BUNDLE"
if ! codesign --verify --deep --strict "$APP_BUNDLE"; then
  echo "error: $APP_BUNDLE does not pass 'codesign --verify --deep --strict'." >&2
  echo "Look for loose files at the .app root (resource bundles belong in Contents/Resources)." >&2
  exit 1
fi
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # A real identity was requested: the widget extension must verify too.
  codesign --verify --strict "$WIDGET_APPEX"
  echo "Signed $APP_BUNDLE and its widget extension with: $SIGN_IDENTITY" >&2
fi

plutil -lint "$INFO_PLIST" >/dev/null
test -x "$APP_BINARY"
test -x "$CLI_BINARY"
test -x "$HOOK_HELPER_BINARY"
test -x "$WIDGET_APPEX/Contents/MacOS/$WIDGET_PRODUCT"
# Every shipped Mach-O must be stamped with the selected SDK and the declared
# minimum OS. Fails when the SDK stamp falls back to the deployment target.
RAFU_EXPECT_MINOS="$MIN_SYSTEM_VERSION" "$ROOT_DIR/script/check_sdk_stamp.sh" \
  "$APP_BINARY" "$CLI_BINARY" "$HOOK_HELPER_BINARY" \
  "$WIDGET_APPEX/Contents/MacOS/$WIDGET_PRODUCT"
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$WIDGET_APPEX/Contents/Info.plist")" = "com.apple.widgetkit-extension"
codesign -d --entitlements - --xml "$WIDGET_APPEX" 2>/dev/null | grep -F "com.apple.security.app-sandbox" >/dev/null
test -s "$APP_ICON"
test "$(plutil -extract CFBundleIconFile raw "$INFO_PLIST")" = "$APP_ICON_NAME"
# The widget link scheme (`RafuDeepLink`): one scheme per variant, so a
# Lightning widget never opens the release app.
test "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$INFO_PLIST")" = "$URL_SCHEME"
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
# No loose resource bundle may sit at the .app root: codesign cannot seal it.
if compgen -G "$APP_BUNDLE/*.bundle" >/dev/null; then
  echo "error: a resource bundle sits at the $APP_BUNDLE root; it belongs in Contents/Resources." >&2
  exit 1
fi
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
    # RAFU_KEEP_STAGE=1 keeps the staged bundle so script/verify.sh can
    # register it with Launch Services before the tests. verify.sh removes it.
    if [[ "${RAFU_KEEP_STAGE:-}" != 1 ]]; then
      rm -rf "$APP_BUNDLE"
    fi
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
