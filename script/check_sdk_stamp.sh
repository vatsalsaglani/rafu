#!/usr/bin/env bash
# Fails when a Mach-O binary is stamped with an SDK older than the selected SDK
# (or, optionally, with the wrong minimum OS).
#
# SwiftPM's Swift Build backend links through the real `clang` with
# `--sysroot`, and that clang cannot read SDKSettings.json from `--sysroot`.
# It falls back to `-platform_version macos <min> <min>`, so
# `LC_BUILD_VERSION` records the deployment target as the SDK version and the
# system treats the binary as linked against that older SDK ("linked on or
# after" behaviour, including WidgetKit). `script/sdk_link_flags.sh` supplies
# the fix at link time; this check proves it.
#
# usage: check_sdk_stamp.sh <mach-o> [<mach-o> ...]
#        check_sdk_stamp.sh --self-test
#   RAFU_SDK_VERSION   overrides `xcrun --show-sdk-version`
#   RAFU_EXPECT_MINOS  when set, also require `minos` to equal this version
#   RAFU_VTOOL         overrides `vtool` (the self-test uses a fake)
set -euo pipefail

VTOOL="${RAFU_VTOOL:-vtool}"

check_binaries() {
  local sdk_version="${RAFU_SDK_VERSION:-$(xcrun --show-sdk-version)}"
  local sdk_major="${sdk_version%%.*}"
  if [[ ! "$sdk_major" =~ ^[0-9]+$ ]]; then
    echo "Cannot read the selected SDK version (got '$sdk_version')." >&2
    return 1
  fi

  local status=0 binary build stamped stamped_major minos
  for binary in "$@"; do
    build="$("$VTOOL" -show-build "$binary" 2>/dev/null || true)"
    # `vtool -show-build` prints `minos X.Y` and `sdk X.Y` per LC_BUILD_VERSION.
    stamped="$(awk '$1 == "sdk" { print $2; exit }' <<<"$build")"
    minos="$(awk '$1 == "minos" { print $2; exit }' <<<"$build")"
    if [[ -z "$stamped" ]]; then
      echo "SDK stamp: no LC_BUILD_VERSION sdk field in $binary" >&2
      status=1
      continue
    fi
    stamped_major="${stamped%%.*}"
    if [[ ! "$stamped_major" =~ ^[0-9]+$ ]] || ((stamped_major < sdk_major)); then
      echo "SDK stamp: $binary is stamped sdk $stamped but the selected SDK is $sdk_version." >&2
      status=1
    fi
    if [[ -n "${RAFU_EXPECT_MINOS:-}" && "$minos" != "$RAFU_EXPECT_MINOS" ]]; then
      echo "SDK stamp: $binary has minos '$minos', expected $RAFU_EXPECT_MINOS." >&2
      status=1
    fi
  done
  return "$status"
}

self_test() {
  local dir fake
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  fake="$dir/vtool"
  # Fake vtool: prints the fixture named by the binary's file name.
  cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
case "$(basename "$2")" in
  ok)    printf 'x:\nLoad command 11\n      cmd LC_BUILD_VERSION\n platform MACOS\n    minos 15.0\n      sdk 27.2\n   ntools 1\n' ;;
  newer) printf 'x:\n platform MACOS\n    minos 15.0\n      sdk 28.0\n' ;;
  stale) printf 'x:\n platform MACOS\n    minos 15.0\n      sdk 15.0\n' ;;
  minor) printf 'x:\n platform MACOS\n    minos 15.0\n      sdk 27.0\n' ;;
  none)  printf 'x:\nLoad command 1\n      cmd LC_SEGMENT_64\n' ;;
  *)     exit 1 ;;
esac
FAKE
  chmod +x "$fake"
  local failures=0
  expect() { # expect <0|1> <label> <command...>
    local want="$1" label="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=1
    if [[ "$got" != "$want" ]]; then
      echo "self-test FAILED: $label (wanted exit $want, got $got)" >&2
      failures=$((failures + 1))
    fi
  }
  export RAFU_VTOOL="$fake" RAFU_SDK_VERSION=27.2
  expect 0 "sdk equals selected" "$0" ok
  expect 0 "sdk newer than selected" "$0" newer
  expect 0 "same major, lower minor passes" "$0" minor
  expect 1 "sdk stamped with the minimum OS" "$0" stale
  expect 1 "no build version command" "$0" none
  expect 1 "one stale binary among good ones" "$0" ok stale ok
  RAFU_EXPECT_MINOS=15.0 expect 0 "minos matches" "$0" ok
  RAFU_EXPECT_MINOS=14.0 expect 1 "minos differs" "$0" ok
  RAFU_SDK_VERSION=26.2 expect 0 "older runner SDK, sdk 27.2 stamp" "$0" ok
  RAFU_SDK_VERSION=26.2 expect 1 "older runner SDK, minimum-OS stamp" "$0" stale
  if ((failures > 0)); then
    return 1
  fi
  echo "check_sdk_stamp self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit
fi
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <mach-o> [<mach-o> ...] | --self-test" >&2
  exit 2
fi
check_binaries "$@"
