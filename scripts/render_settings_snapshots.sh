#!/usr/bin/env bash
# Render every Settings page offscreen to PNG (light and dark, ru and en).
# No window is shown and no preferences of the user are read or written.
# Usage: scripts/render_settings_snapshots.sh [prefix] [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-settings}"
OUT="${2:-$ROOT/.build/settings-ui}"

cd "$ROOT"
swift build --product RuSwitcher -Xswiftc -warnings-as-errors >/dev/null
BIN="$(swift build --product RuSwitcher --show-bin-path)/RuSwitcher"

for lang in ru en; do
    "$BIN" --render-settings-snapshots "$OUT" "$PREFIX-$lang" \
        -com.ruswitcher.interfaceLanguage "$lang"
done
