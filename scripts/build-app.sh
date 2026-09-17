#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIGURATION="${CONFIGURATION:-release}"
JOBS="${JOBS:-4}"
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_NAME="Goat Voice"
XPC_NAME="GoatVoiceSTT"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
XPC_BUNDLE="$APP_BUNDLE/Contents/XPCServices/$XPC_NAME.xpc"

cd "$ROOT"

echo "Building GoatVoiceApp ($CONFIGURATION, -j$JOBS, scratch $SCRATCH_PATH)"
xcrun swift build -c "$CONFIGURATION" -j "$JOBS" --scratch-path "$SCRATCH_PATH" --product GoatVoiceApp
echo "Building GoatVoiceService ($CONFIGURATION, -j$JOBS)"
xcrun swift build -c "$CONFIGURATION" -j "$JOBS" --scratch-path "$SCRATCH_PATH" --product GoatVoiceService

BIN_PATH="$(xcrun swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH_PATH" --show-bin-path)"
APP_PRODUCT="$BIN_PATH/GoatVoiceApp"
XPC_PRODUCT="$BIN_PATH/GoatVoiceService"

for expected in "$APP_PRODUCT" "$XPC_PRODUCT"; do
    if [[ ! -x "$expected" ]]; then
        echo "error: expected product missing: $expected" >&2
        exit 1
    fi
done

SPARKLE_FW=""
if [[ -d "$BIN_PATH/Sparkle.framework" ]]; then
    SPARKLE_FW="$BIN_PATH/Sparkle.framework"
else
    while IFS= read -r candidate; do
        if [[ -d "$candidate" && "$candidate" == *macos* ]]; then
            SPARKLE_FW="$candidate"
            break
        fi
    done < <(find "$SCRATCH_PATH/artifacts" -name "Sparkle.framework" -maxdepth 6 2>/dev/null)
fi

if [[ -z "$SPARKLE_FW" ]]; then
    echo "error: Sparkle.framework not found; GoatVoiceApp links Sparkle and cannot load without it" >&2
    exit 1
fi

if [[ -d "$APP_BUNDLE" ]]; then
    PREVIOUS_BUNDLE=$(mktemp -d "$BUILD_DIR/previous-bundle.XXXXXX")
    mv "$APP_BUNDLE" "$PREVIOUS_BUNDLE/$APP_NAME.app"
fi
mkdir -p \
    "$APP_BUNDLE/Contents/MacOS" \
    "$APP_BUNDLE/Contents/Resources" \
    "$APP_BUNDLE/Contents/Frameworks" \
    "$XPC_BUNDLE/Contents/MacOS" \
    "$XPC_BUNDLE/Contents/Resources"

cp "$APP_PRODUCT" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$XPC_PRODUCT" "$XPC_BUNDLE/Contents/MacOS/GoatVoiceService"
cp "$ROOT/Resources/GoatVoiceApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ -f "$ROOT/Resources/GoatVoiceService/Info.plist" ]]; then
    cp "$ROOT/Resources/GoatVoiceService/Info.plist" "$XPC_BUNDLE/Contents/Info.plist"
else
    echo "error: Resources/GoatVoiceService/Info.plist missing" >&2
    exit 1
fi

python3 "$ROOT/tools/release.py" configure-bundle "$APP_BUNDLE"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.txt" "$APP_BUNDLE/Contents/Resources/"

if [[ -d "$ROOT/Resources/Models" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/Models"
    cp -R "$ROOT/Resources/Models/" "$APP_BUNDLE/Contents/Resources/Models/"
    echo "Embedded model resources: $(ls "$ROOT/Resources/Models" | tr '\n' ' ')"
fi

for artifact in "$BIN_PATH"/*.bundle "$BIN_PATH"/*.metallib "$BIN_PATH"/*.mo "$BIN_PATH"/*.mlmodelc; do
    if [[ -e "$artifact" ]]; then
        cp -R "$artifact" "$XPC_BUNDLE/Contents/Resources/"
        echo "Embedded service runtime artifact: $(basename "$artifact")"
    fi
done

ditto "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
echo "Embedded Sparkle.framework from $SPARKLE_FW"

if ! command -v codesign >/dev/null 2>&1; then
    echo "error: codesign unavailable; cannot produce a runnable bundle" >&2
    exit 1
fi

sign() {
    if ! codesign --force --sign - "$1" >/dev/null; then
        echo "error: ad-hoc signing failed: $1" >&2
        exit 1
    fi
    echo "Ad-hoc signed $(basename "$1")"
}

SPARKLE_DEST="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
while IFS= read -r helper; do
    sign "$helper"
done < <(find "$SPARKLE_DEST" \( -name "*.xpc" -o -name "*.app" \) -mindepth 3 2>/dev/null | sort -r)
while IFS= read -r helper; do
    sign "$helper"
done < <(find "$SPARKLE_DEST" -type f -name "Autoupdate" 2>/dev/null)
sign "$SPARKLE_DEST"
sign "$XPC_BUNDLE"
sign "$APP_BUNDLE"

echo "Created $APP_BUNDLE"
