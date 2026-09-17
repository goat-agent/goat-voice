#!/usr/bin/env bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}"
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'Apple Silicon is required for the inference dependencies' >&2
    exit 1
fi
xcrun swift --version
xcodebuild -version
if ! xcrun metal --version >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain
fi
xcrun metal --version
xcrun swift package resolve --force-resolved-versions
