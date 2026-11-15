#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [output-directory]" >&2
    exit 64
fi
OUT="${1:-$ROOT/.build/test-host/apps}"
SIGN_ID="${SIGN_ID:-RuSwitcher Local Code Signing}"
if [ "$SIGN_ID" = "-" ] || [ "${RUSWITCH_UNSIGNED_BUNDLE:-0}" = "1" ]; then
    echo "FAIL: test hosts require a reusable signing identity" >&2
    exit 1
fi
export RUSWITCH_TEST_HOST=1
BUILD_FLAGS=(-c release --scratch-path "$ROOT/.build/test-host" --product CerfSwitcherTestHost -Xswiftc -warnings-as-errors)
cd "$ROOT"
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
MODEL="$BIN_DIR/RuSwitcher_RuSwitcherCore.bundle/Contents/Resources/language-model-v1.bin"
test -x "$BIN_DIR/CerfSwitcherTestHost"
test -f "$MODEL"

mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.test-host.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/CerfSwitcherTestHost.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CerfSwitcherTestHost" "$APP/Contents/MacOS/CerfSwitcherTestHost"
python3 - "$ROOT" "$APP" <<'PY'
import json
from pathlib import Path
import plistlib
import sys

root, app = map(Path, sys.argv[1:])
version = json.loads((root / "version.json").read_text())
info = plistlib.loads((root / "Info.plist").read_bytes())
info.update(CFBundleExecutable="CerfSwitcherTestHost",
            CFBundleIdentifier="com.cerfswitcher.testhost",
            CFBundleName="CerfSwitcher Test Host", CFBundleDisplayName="CerfSwitcher Test Host",
            CFBundleShortVersionString=version["version"], CFBundleVersion=str(version["build"]),
            RSDevTag=version.get("dev", ""), RSTestHost=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
(app / "Contents/PkgInfo").write_bytes(b"APPL????")
PY
cp "$MODEL" "$APP/Contents/Resources/language-model-v1.bin"
cp "$ROOT/RuSwitcher.icns" "$ROOT/THIRD_PARTY_NOTICES.md" \
    "$ROOT/scripts/data/SCOWL_COPYRIGHT.txt" \
    "$ROOT/scripts/data/RUSSIAN_HUNSPELL_COPYRIGHT.txt" "$APP/Contents/Resources/"
codesign --force --deep --sign "$SIGN_ID" --options runtime \
    --entitlements "$ROOT/RuSwitcher.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! printf '%s\n' "$DETAILS" | grep -Fqx "Authority=$SIGN_ID"; then
    echo "FAIL: test host signing authority does not match $SIGN_ID" >&2
    exit 1
fi
rm -rf "$OUT/CerfSwitcherTestHost.app"
mv "$APP" "$OUT/CerfSwitcherTestHost.app"
echo "TEST HOST: $OUT/CerfSwitcherTestHost.app"
