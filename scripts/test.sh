#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
JOBS="${JOBS:-4}"
SCRATCH_PATH="${SCRATCH_PATH:-$PROJECT_ROOT/.build}"
TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-$PROJECT_ROOT/build/test-results}"

cd "$PROJECT_ROOT"
mkdir -p "$TEST_OUTPUT_DIR"
xcrun swift build --build-system swiftbuild --build-tests -j "$JOBS" --scratch-path "$SCRATCH_PATH"
BIN_PATH="$(xcrun swift build --build-system swiftbuild --scratch-path "$SCRATCH_PATH" --show-bin-path)"
SPARKLE_FRAMEWORK="$SCRATCH_PATH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo 'The pinned Sparkle framework is missing from resolved package artifacts' >&2
    exit 1
fi
mkdir -p "$BIN_PATH/PackageFrameworks"
ditto "$SPARKLE_FRAMEWORK" "$BIN_PATH/PackageFrameworks/Sparkle.framework"
xcrun swift test --build-system swiftbuild --skip-build -j "$JOBS" \
    --scratch-path "$SCRATCH_PATH" --xunit-output "$TEST_OUTPUT_DIR/results.xml" "$@" \
    2>&1 | tee "$TEST_OUTPUT_DIR/tests.log"
