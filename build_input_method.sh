#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="RuSwitcherInputMethod"
APP_NAME="RuSwitcherInputMethod"
DISPLAY_NAME="Cerf Switcher Input Method"
BUNDLE_ID="com.cerfswitcher.inputmethod"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
VERSION_JSON="$PROJECT_DIR/version.json"

SHORT_VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('$VERSION_JSON'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('$VERSION_JSON')).get('build','1'))")

echo "=== Building $DISPLAY_NAME $SHORT_VERSION ($BUILD_VERSION) ==="
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64 --product "$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$PRODUCT_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
cp "$PROJECT_DIR/InputMethod/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/RuSwitcher.icns" "$APP_BUNDLE/Contents/Resources/RuSwitcher.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"

CORE_RESOURCE_BUNDLE="$BUILD_DIR/RuSwitcher_RuSwitcherCore.bundle"
MODEL_RESOURCE="$CORE_RESOURCE_BUNDLE/Contents/Resources/language-model-v1.bin"
if [ ! -f "$MODEL_RESOURCE" ]; then
    echo "ERROR: V3 model not found: $MODEL_RESOURCE"
    exit 1
fi
cp "$MODEL_RESOURCE" "$APP_BUNDLE/Contents/Resources/language-model-v1.bin"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME")
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
    echo "ERROR: Input Method is not universal: $ARCHS"
    exit 1
fi

DEV_SIGN_ID="Developer ID Application: Rashid Nasibulin (9GEWCZ59HK)"
LOCAL_SIGN_ID="RuSwitcher Local Code Signing"
SIGN_ID="${SIGN_ID:-}"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [ -z "$SIGN_ID" ]; then
    if echo "$IDENTITIES" | grep -Fq "\"$DEV_SIGN_ID\""; then
        SIGN_ID="$DEV_SIGN_ID"
    elif echo "$IDENTITIES" | grep -Fq "\"$LOCAL_SIGN_ID\""; then
        SIGN_ID="$LOCAL_SIGN_ID"
    else
        echo "ERROR: no reusable signing identity found"
        exit 1
    fi
fi

if [[ "$SIGN_ID" == Developer\ ID\ Application:* ]]; then
    codesign --force --deep --sign "$SIGN_ID" --options runtime "$APP_BUNDLE"
else
    codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNATURE_DETAILS=$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)
if ! echo "$SIGNATURE_DETAILS" | grep -Fq "Authority=$SIGN_ID"; then
    echo "ERROR: signature authority does not match $SIGN_ID"
    exit 1
fi
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
"$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" --self-check

echo "Built: $APP_BUNDLE"
echo "Bundle ID: $BUNDLE_ID"
echo "Architectures: $ARCHS"
