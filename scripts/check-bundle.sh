#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_BUNDLE="${1:-$PROJECT_ROOT/build/Goat Voice.app}"

codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "$PROJECT_ROOT/build"
CHECK_DIR="$(mktemp -d "$PROJECT_ROOT/build/bundle-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_APP="$CHECK_DIR/XPCCheck.app"

ditto "$APP_BUNDLE" "$CHECK_APP"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_ROOT"/Sources/GoatVoicePlatform/XPC/*.swift \
    "$PROJECT_ROOT/tools/CheckXPC.swift" \
    -o "$CHECK_APP/Contents/MacOS/Goat Voice"
codesign --force --sign - "$CHECK_APP"
"$CHECK_APP/Contents/MacOS/Goat Voice"
