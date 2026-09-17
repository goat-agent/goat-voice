#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_BUNDLE="${APP_BUNDLE:-$PROJECT_ROOT/build/Goat Voice.app}"
RELEASE_DIRECTORY="${RELEASE_DIRECTORY:-$PROJECT_ROOT/build/release}"
SCRATCH_PATH="${SCRATCH_PATH:-$PROJECT_ROOT/.build}"

cd "$PROJECT_ROOT"
python3 tools/release.py artifact-metadata "$APP_BUNDLE" "$RELEASE_DIRECTORY"
archive_name=$(python3 tools/release.py metadata | python3 -c 'import json,sys; print(json.load(sys.stdin)["archive"])')
bash scripts/create-dmg.sh "$APP_BUNDLE" "$RELEASE_DIRECTORY/$archive_name"
mkdir -p "$RELEASE_DIRECTORY/tools"
cp "$SCRATCH_PATH/artifacts/sparkle/Sparkle/bin/sign_update" "$RELEASE_DIRECTORY/tools/sign_update"
xcrun swiftc -parse-as-library tools/VerifyUpdate.swift -o "$RELEASE_DIRECTORY/tools/verify_update"
echo "Prepared release artifacts in $RELEASE_DIRECTORY"
