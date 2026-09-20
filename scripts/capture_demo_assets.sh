#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
mkdir -p "$ROOT/docs/assets"

cd "$ROOT/mobile"
HOME="$ROOT/.home" CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true \
  "$FLUTTER_BIN" --no-version-check test \
  tool/demo_screenshots_test.dart --update-goldens
python3 "$ROOT/scripts/check_demo_assets.py"

printf 'Sanitized demo screenshots written to %s\n' "$ROOT/docs/assets"
