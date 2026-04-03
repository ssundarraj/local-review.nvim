#!/usr/bin/env sh

set -eu

if ! command -v busted >/dev/null 2>&1; then
  echo "busted is required to run tests. Install it and re-run ./scripts/test.sh." >&2
  exit 1
fi

busted tests/positioning_spec.lua
