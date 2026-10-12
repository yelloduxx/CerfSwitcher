#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN='\.contains([[:space:]]*([]),;}]|$)|\(([A-Za-z_]+:)+\))'

cd "$ROOT"
if git grep -nE "$PATTERN" -- '*.swift'; then
  echo "Pass contains predicates as closures: Swift 6.4 -O miscompiles bound references (swiftlang/swift#92539)" >&2
  exit 1
fi
