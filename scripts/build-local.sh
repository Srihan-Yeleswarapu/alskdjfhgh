#!/usr/bin/env bash
#
# build-local.sh — one-command Mac build that mirrors CI (.github/workflows/build.yml).
#
# Usage:
#   scripts/build-local.sh              # Release archive build (same flags as CI)
#   scripts/build-local.sh --debug      # Debug build for the iOS Simulator instead
#
# Requirements (installed once):
#   brew install xcodegen
#   # optional, for pretty logs:
#   brew install xcbeautify
#
# The script fails (non-zero exit) if the build produces ANY compiler warning,
# keeping the local and CI warning count at zero.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---release}"
LOG_DIR=".build-local"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build.log"

echo "==> Generating Xcode project (xcodegen)"
xcodegen generate

# Match CI's signing overrides so the archive step works without a dev account.
COMMON_FLAGS=(
  -project SmartSpeedCompanion.xcodeproj
  -scheme SmartSpeedCompanion
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

if [ "$MODE" = "--debug" ]; then
  echo "==> Building (Debug, iOS Simulator)"
  BUILD_CMD=(xcodebuild build "${COMMON_FLAGS[@]}" -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator')
else
  echo "==> Archiving (Release, device) — same flags as CI"
  BUILD_CMD=(xcodebuild clean archive "${COMMON_FLAGS[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath ./SmartSpeedCompanion.xcarchive)
fi

echo "==> Running build (full log: $LOG_FILE)"
if command -v xcbeautify >/dev/null 2>&1; then
  "${BUILD_CMD[@]}" 2>&1 | tee "$LOG_FILE" | xcbeautify
  PIPESTATUS=("${PIPESTATUS[@]}")
  [ "${PIPESTATUS[0]}" -ne 0 ] && exit "${PIPESTATUS[0]}"
else
  "${BUILD_CMD[@]}" 2>&1 | tee "$LOG_FILE"
  PIPESTATUS=("${PIPESTATUS[@]}")
  [ "${PIPESTATUS[0]}" -ne 0 ] && exit "${PIPESTATUS[0]}"
fi

echo
echo "==> Warning check"
WARN_COUNT=$(grep -c "warning:" "$LOG_FILE" || true)
if [ "$WARN_COUNT" -ne 0 ]; then
  echo "✗ FAIL: $WARN_COUNT warning(s) — this repo is warning-free by policy:"
  grep "warning:" "$LOG_FILE" | sort -u | head -20
  exit 1
fi
echo "✓ Build succeeded with ZERO warnings."
