#!/bin/bash

# Shared identity gate for native probes. Source this file, then call
# ruswitch_validate_test_app with the repository root.
ruswitch_validate_test_app() {
    local root="$1"
    local plist expected_version expected_build reference reference_plist
    local reference_id reference_version reference_build actual_hash reference_hash

    RUSWITCH_APP="${RUSWITCH_APP:-/Applications/RuSwitcherPro.app}"
    plist="$RUSWITCH_APP/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
        echo "FAIL: test application is missing: $RUSWITCH_APP" >&2
        return 1
    fi

    RUSWITCH_APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
    RUSWITCH_APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    RUSWITCH_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    RUSWITCH_APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    RUSWITCH_APP_EXEC="$RUSWITCH_APP/Contents/MacOS/$RUSWITCH_APP_EXECUTABLE"
    test -x "$RUSWITCH_APP_EXEC"

    local expected_id="${RUSWITCH_EXPECTED_BUNDLE_ID:-com.ruswitcher.pro}"
    if [ "$RUSWITCH_APP_BUNDLE_ID" != "$expected_id" ]; then
        echo "FAIL: expected bundle ID $expected_id, got $RUSWITCH_APP_BUNDLE_ID" >&2
        return 1
    fi

    expected_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$root/version.json")"
    expected_build="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["build"])' "$root/version.json")"
    if [ "${RUSWITCH_ALLOW_VERSION_MISMATCH:-0}" != "1" ] && {
        [ "$RUSWITCH_APP_VERSION" != "$expected_version" ] ||
        [ "$RUSWITCH_APP_BUILD" != "$expected_build" ];
    }; then
        echo "FAIL: expected $expected_version+$expected_build, got $RUSWITCH_APP_VERSION+$RUSWITCH_APP_BUILD" >&2
        return 1
    fi

    actual_hash="$(shasum -a 256 "$RUSWITCH_APP_EXEC" | awk '{print $1}')"
    reference="${RUSWITCH_REFERENCE_APP:-$root/RuSwitcherPro.app}"
    reference_plist="$reference/Contents/Info.plist"
    if [ "${RUSWITCH_ALLOW_HASH_MISMATCH:-0}" != "1" ]; then
        if [ ! -f "$reference_plist" ]; then
            echo "FAIL: source-built reference application is missing: $reference" >&2
            echo "Build it first or set RUSWITCH_REFERENCE_APP explicitly." >&2
            return 1
        fi
        reference_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$reference_plist")"
        reference_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$reference_plist")"
        reference_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$reference_plist")"
        reference_hash="$(shasum -a 256 "$reference/Contents/MacOS/$RUSWITCH_APP_EXECUTABLE" | awk '{print $1}')"
        if [ "$reference_id" != "$RUSWITCH_APP_BUNDLE_ID" ] ||
           [ "$reference_version" != "$RUSWITCH_APP_VERSION" ] ||
           [ "$reference_build" != "$RUSWITCH_APP_BUILD" ] ||
           [ "$reference_hash" != "$actual_hash" ]; then
            echo "FAIL: installed application does not match $reference" >&2
            return 1
        fi
    fi

    export RUSWITCH_APP RUSWITCH_APP_EXECUTABLE RUSWITCH_APP_BUNDLE_ID
    export RUSWITCH_APP_VERSION RUSWITCH_APP_BUILD RUSWITCH_APP_EXEC
    printf 'TEST APP: %s %s+%s %s sha256=%s\n' \
        "$RUSWITCH_APP_BUNDLE_ID" "$RUSWITCH_APP_VERSION" "$RUSWITCH_APP_BUILD" \
        "$RUSWITCH_APP" "$actual_hash" >&2
}
