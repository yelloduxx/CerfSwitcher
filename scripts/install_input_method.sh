#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$PROJECT_DIR/RuSwitcherInputMethod.app"
INSTALL_ROOT="$HOME/Library/Input Methods"
TARGET="$INSTALL_ROOT/RuSwitcherInputMethod.app"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$INSTALL_ROOT/RuSwitcherInputMethod-backup-$TIMESTAMP.app"

if [ ! -d "$SOURCE" ]; then
    echo "ERROR: build the Input Method first: bash build_input_method.sh"
    exit 1
fi
codesign --verify --deep --strict "$SOURCE"
mkdir -p "$INSTALL_ROOT"
STAGING=$(mktemp -d "$INSTALL_ROOT/.ruswitcher-input-method.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$SOURCE" "$STAGING/RuSwitcherInputMethod.app"
codesign --verify --deep --strict "$STAGING/RuSwitcherInputMethod.app"

pkill -x RuSwitcherInputMethod 2>/dev/null || true
if [ -d "$TARGET" ]; then
    mv "$TARGET" "$BACKUP"
fi
mv "$STAGING/RuSwitcherInputMethod.app" "$TARGET"

register_installed_input_method() {
    "$TARGET/Contents/MacOS/RuSwitcherInputMethod" --register || return 1
    killall TextInputMenuAgent imklaunchagent 2>/dev/null || true
    sleep 1
    "$TARGET/Contents/MacOS/RuSwitcherInputMethod" --register || return 1
    "$TARGET/Contents/MacOS/RuSwitcherInputMethod" --verify-registration || return 1
}

if ! register_installed_input_method; then
    echo "ERROR: macOS did not enable both RuSwitcher input sources" >&2
    echo "macOS requires an Apple Development or Developer ID identity for InputMethodKit." >&2
    echo "A self-signed identity is rejected by AMFI even when added to System trust." >&2
    pkill -x RuSwitcherInputMethod 2>/dev/null || true
    rm -rf "$TARGET"
    if [ -d "$BACKUP" ]; then
        mv "$BACKUP" "$TARGET"
        "$TARGET/Contents/MacOS/RuSwitcherInputMethod" --register 2>/dev/null || true
        killall TextInputMenuAgent imklaunchagent 2>/dev/null || true
    fi
    exit 1
fi

echo "Installed and registered: $TARGET"
if [ -d "$BACKUP" ]; then
    echo "Previous bundle: $BACKUP"
fi
echo "Select RuSwitcher EN or RuSwitcher RU in System Settings > Keyboard > Input Sources."
