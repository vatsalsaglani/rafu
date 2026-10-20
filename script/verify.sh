#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
EDITOR_DRAG_TYPE="dev.vatsalsaglani.rafu.editor-drag-v2"
STAGE_APP="$ROOT_DIR/dist/.RafuLightning-stage.app"
ICON_CHECK="$(mktemp -d)"

# Unregister before removing: lsregister cannot scan a deleted bundle.
release_stage() {
  if [[ -d "$STAGE_APP" ]]; then
    "$LSREGISTER" -u "$STAGE_APP" >/dev/null 2>&1 || true
    rm -rf "$STAGE_APP"
  fi
}
trap 'rm -rf "$ICON_CHECK"; release_stage' EXIT

./script/format.sh --lint
jq empty Resources/Themes/*.json
xmllint --noout Resources/AppIcon/rafu-icon-seam.svg
./script/generate_app_icon.sh "$ICON_CHECK/Rafu.icns"
test -s "$ICON_CHECK/Rafu.icns"
./script/build.sh

# AppKit routes the private drag type to SwiftUI `.onDrop` targets only
# through the conformance Launch Services registered from a bundle's
# UTExportedTypeDeclarations. A fresh CI runner has never registered a Rafu
# bundle, so EditorTabStripDropRoutingTests needs the staged Lightning bundle
# registered first. Registering launches nothing. The tests then require the
# declaration, so a closed gate fails here instead of skipping. See
# docs/references/drag-and-drop-custom-uttype.md.
RAFU_APP_NAME="Rafu Lightning" RAFU_KEEP_STAGE=1 ./script/build_and_run.sh --stage
"$LSREGISTER" -f "$STAGE_APP"
if ! "$LSREGISTER" -dump | grep -F "$EDITOR_DRAG_TYPE" >/dev/null; then
  echo "Launch Services does not declare $EDITOR_DRAG_TYPE after registering $STAGE_APP." >&2
  exit 1
fi

RAFU_REQUIRE_DRAG_TYPE_DECLARATION=1 ./script/test.sh
release_stage
swift run rafu --help >/dev/null
swift run rafu --version >/dev/null
./script/build_and_run.sh --stage
