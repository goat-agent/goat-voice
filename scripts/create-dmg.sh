#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/build/Goat Voice.app}"
OUTPUT_IMAGE="${2:-$PROJECT_ROOT/build/Goat Voice-dev.dmg}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "App bundle missing. Run scripts/build-app.sh first." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
STAGING_DIR="$(mktemp -d "$PROJECT_ROOT/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_BUNDLE" "$STAGING_DIR/Goat Voice.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname 'Goat Voice' -srcfolder "$STAGING_DIR" \
    -format UDZO -ov "$OUTPUT_IMAGE"
hdiutil verify "$OUTPUT_IMAGE"
echo "Created local development image: $OUTPUT_IMAGE"
