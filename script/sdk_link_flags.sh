#!/usr/bin/env bash
# Prints the `swift build` flags that make Mach-O binaries record the real SDK.
#
# SwiftPM's Swift Build backend links through the real `clang --sysroot`,
# which cannot read the SDK version and so passes
# `-platform_version macos <min> <min>`. The binary is then stamped
# `sdk <min>` instead of the selected SDK. A later `-platform_version` for the
# same platform wins in ld, so this appends the correct pair. Setting
# `SDKROOT` does not help: Swift Build does not forward it to the link step.
#
# The SDK version is read at build time (`xcrun --show-sdk-version`), so a
# runner with a different SDK stamps its own SDK. The minimum OS stays the
# value passed in, which must match `.macOS(.v15)` in Package.swift.
#
# usage: sdk_link_flags.sh <min-os>        prints flags, space separated
#   RAFU_SDK_VERSION overrides `xcrun --show-sdk-version`.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <min-os>" >&2
  exit 2
fi

MIN_OS="$1"
SDK_VERSION="${RAFU_SDK_VERSION:-$(xcrun --show-sdk-version)}"
if [[ ! "$MIN_OS" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$SDK_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "sdk_link_flags: unusable version (min '$MIN_OS', sdk '$SDK_VERSION')." >&2
  exit 1
fi

echo "-Xlinker -platform_version -Xlinker macos -Xlinker $MIN_OS -Xlinker $SDK_VERSION"
