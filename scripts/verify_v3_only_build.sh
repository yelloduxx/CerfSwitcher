#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESCRIPTION="$ROOT/.build/v3-only-package-description.json"
REPORT="$ROOT/.build/v3-only-simulator-report.json"
APP="${1:-$ROOT/RuSwitcherPro.app}"

cd "$ROOT"
mkdir -p "$ROOT/.build"
swift package describe --type json > "$DESCRIPTION"

python3 - "$DESCRIPTION" <<'PY'
import json
import sys

package = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {target["name"]: target for target in package["targets"]}
for forbidden in ("RuSwitcherExperimentalV4", "SmartAutoConvertEngine"):
    if forbidden in targets:
        raise SystemExit(f"forbidden root target: {forbidden}")

app_dependencies = set(targets["RuSwitcher"]["target_dependencies"])
if app_dependencies != {"RuSwitcherCore", "RuSwitcherAppSupport"}:
    raise SystemExit(f"unexpected RuSwitcher dependencies: {sorted(app_dependencies)}")
if set(targets["RuSwitcherSimulator"]["target_dependencies"]) != {"RuSwitcherCore"}:
    raise SystemExit("corpus simulator is not V3-only")
typing_dependencies = set(targets["RuSwitcherTypingSimulator"]["target_dependencies"])
if typing_dependencies != {"RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherTestSupport"}:
    raise SystemExit(f"unexpected typing simulator dependencies: {sorted(typing_dependencies)}")
PY

for removed in \
    Sources/RuSwitcherCore/SmartAutoConvertEngine.swift \
    Sources/RuSwitcherCore/TypingLanguageState.swift \
    Sources/RuSwitcherCore/LocalLanguageModel.swift \
    Sources/RuSwitcherCore/LayoutDetector.swift; do
    if [ -e "$ROOT/$removed" ]; then
        echo "FAIL: removed V2 source still exists: $removed"
        exit 1
    fi
done

if grep -R -E -q 'SmartAutoConvertEngine|ContextualLayoutDecoder|ContextualLayoutModel|RuSwitcherExperimentalV4|LayoutDetector' \
    "$ROOT/Sources/RuSwitcher"; then
    echo "FAIL: production executable still references an alternate decoder"
    exit 1
fi

swift run -c release RuSwitcherSimulator --jobs 4 --limit 100 --output "$REPORT" >/dev/null
jq -e '.engine == "v3" and .failed == 0' "$REPORT" >/dev/null

if [ -d "$APP" ]; then
    APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
    BINARY="$APP/Contents/MacOS/$APP_EXECUTABLE"
    MODEL="$APP/Contents/Resources/language-model-v1.bin"
    if [ ! -f "$MODEL" ]; then
        echo "FAIL: language model is missing from the application bundle: $MODEL"
        exit 1
    fi
    if [ ! -x "$BINARY" ]; then
        echo "FAIL: application executable is missing or not executable: $BINARY"
        exit 1
    fi
    if ! ARCHITECTURES="$(lipo -archs "$BINARY")"; then
        echo "FAIL: application executable is not a Mach-O binary: $BINARY"
        exit 1
    fi
    for architecture in arm64 x86_64; do
        case " $ARCHITECTURES " in
        *" $architecture "*) ;;
        *)
            echo "FAIL: application executable is not universal, lipo reports: $ARCHITECTURES"
            exit 1
            ;;
        esac
    done
    if find "$APP/Contents" \( -iname '*v4*' -o -iname '*LayoutReranker*' \) -print -quit | grep -q .; then
        echo "FAIL: V4 artifact found in application bundle"
        exit 1
    fi
    LINKED_LIBRARIES="$(otool -L "$BINARY")"
    if grep -E 'CoreML' <<<"$LINKED_LIBRARIES" >/dev/null; then
        echo "FAIL: production executable links CoreML"
        exit 1
    fi
    SYMBOLS="$(nm -j "$BINARY")"
    if grep -E 'SmartAutoConvertEngine|ContextualLayoutDecoder|ContextualLayoutModel' <<<"$SYMBOLS" >/dev/null; then
        echo "FAIL: alternate decoder symbol found in application executable"
        exit 1
    fi
    echo "PASS: production package, simulator and app bundle are V3-only"
elif [ "$#" -gt 0 ]; then
    echo "FAIL: application bundle not found: $APP"
    exit 1
else
    echo "SKIP: app bundle checks, no bundle at $APP"
    echo "PASS: production package and simulator are V3-only"
fi
