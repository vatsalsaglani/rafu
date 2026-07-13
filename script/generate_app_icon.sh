#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/Resources/AppIcon/rafu-icon-seam.svg"
OUTPUT_ICNS="${1:-$ROOT_DIR/dist/Rafu.icns}"

if [[ ! -f "$SOURCE_SVG" ]]; then
  echo "missing app icon source: $SOURCE_SVG" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/Rafu.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT_ICNS")"

render() {
  local pixels="$1"
  local filename="$2"
  sips -s format png -z "$pixels" "$pixels" "$SOURCE_SVG" \
    --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns "$ICONSET" --output "$OUTPUT_ICNS"
test -s "$OUTPUT_ICNS"

