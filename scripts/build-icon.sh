#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$PWD/build/dashcam-icon-compiled}"
mkdir -p "$OUTPUT"
# Compile the actual Icon Composer source. Assets.car retains the independent
# glass layers and appearances; AppIcon.icns is the pre-macOS 26 fallback.
xcrun actool native/Assets/AppIcon.icon \
  --compile "$OUTPUT" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PWD/build/dashcam-icon-info.plist" \
  --output-format human-readable-text --warnings --errors
test -s "$OUTPUT/Assets.car"
test -s "$OUTPUT/AppIcon.icns"
