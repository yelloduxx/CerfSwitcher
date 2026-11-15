#!/usr/bin/env bash
# Render every Settings page offscreen to PNG (light and dark, ru and en).
# No window is shown and no preferences of the user are read or written.
# Usage: scripts/render_settings_snapshots.sh [prefix] [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-settings}"
OUT="${2:-$ROOT/.build/settings-ui}"

cd "$ROOT"
bash "$ROOT/scripts/build_test_host.sh" >/dev/null
source "$ROOT/scripts/ruswitch_test_app.sh"
ruswitch_validate_test_app "$ROOT"

for lang in ru en; do
    "$RUSWITCH_APP_EXEC" --render-settings-snapshots "$OUT" "$PREFIX-$lang" \
        -com.ruswitcher.interfaceLanguage "$lang"
done
