#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---lint}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

case "$MODE" in
  --lint|lint)
    swift format lint --recursive --parallel --strict Sources Tests
    swift format lint --strict Package.swift
    ;;
  --fix|fix)
    swift format format --recursive --parallel --in-place Sources Tests
    swift format format --in-place Package.swift
    ;;
  *)
    echo "usage: $0 [--lint|--fix]" >&2
    exit 2
    ;;
esac

