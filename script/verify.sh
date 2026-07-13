#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/format.sh --lint
jq empty Resources/Themes/*.json
xmllint --noout Resources/AppIcon/rafu-icon-seam.svg
ICON_CHECK="$(mktemp -d)"
trap 'rm -rf "$ICON_CHECK"' EXIT
./script/generate_app_icon.sh "$ICON_CHECK/Rafu.icns"
test -s "$ICON_CHECK/Rafu.icns"
./script/build.sh
./script/test.sh
swift run rafu --help >/dev/null
swift run rafu --version >/dev/null
./script/build_and_run.sh --stage
