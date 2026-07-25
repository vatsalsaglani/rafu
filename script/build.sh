#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Never block silently on a busy or stale `.build/.lock` — see
# script/await_build_lock.sh and AGENTS.md "Build lock".
"$ROOT_DIR/script/await_build_lock.sh"

swift build "$@"

