#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# RAFU_TEST_FLAGS lets CI inject flags (e.g. --no-parallel) without changing
# the local default. Word splitting on the expansion is intentional.
# shellcheck disable=SC2086
swift test ${RAFU_TEST_FLAGS:-} "$@"

