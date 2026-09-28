#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/Dashcam.app"
DESTINATION="$HOME/Applications/Dashcam.app"
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
codesign --verify --deep --strict "$SOURCE"
if codesign -d -r- "$SOURCE" 2>&1 | grep -q 'designated => cdhash'; then
  echo 'Rebuild with a stable signing certificate before installing.' >&2
  exit 1
fi
if pgrep -x JevDashcam >/dev/null || pgrep -x JevNote >/dev/null; then
  echo 'Quit Dashcam / Jev Note before installing the update.' >&2
  exit 1
fi
mkdir -p "$HOME/Applications" build/backups
if [[ -d "$DESTINATION" ]]; then
  ditto -c -k --keepParent "$DESTINATION" "build/backups/Dashcam-$(date +%Y%m%d-%H%M%S).zip"
fi
# Retire the previous bundle name without leaving another launchable copy.
LEGACY="$HOME/Applications/Jev-dashcam.app"
if [[ -d "$LEGACY" ]]; then
  if [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$LEGACY/Contents/Info.plist") != ai.jevnote.mac ]]; then
    echo 'The old bundle belongs to another app; refusing to replace it.' >&2
    exit 1
  fi
  ditto -c -k --keepParent "$LEGACY" "build/backups/Jev-dashcam-$(date +%Y%m%d-%H%M%S).zip"
  "$REGISTER" -u "$LEGACY" || true
  # A non-app suffix keeps the verified backup out of LaunchServices.
  mv "$LEGACY" "build/backups/Jev-dashcam-$(date +%Y%m%d-%H%M%S).retired"
fi
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
"$REGISTER" -u "$SOURCE" || true
"$REGISTER" -f "$DESTINATION"
echo "Installed: $DESTINATION"
