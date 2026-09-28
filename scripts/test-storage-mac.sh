#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/dashcam-storage-app.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
APP="$FIXTURE/StorageTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/service" build/module-cache
cp "${JEV_NODE_BINARY:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}" "$APP/Contents/Resources/runtime/node"
cp storage-migration.mjs server.mjs core.mjs capture-migration.mjs window-exclusions.mjs capture-policy.mjs legacy-project-migration.mjs "$APP/Contents/Resources/service/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.jevnote.storage-tests</string><key>CFBundleExecutable</key><string>StorageTests</string></dict></plist>
PLIST
swiftc -parse-as-library -module-cache-path build/module-cache native/WindowExclusion.swift native/MacApp/Store.swift native/MacApp/StorageLocation.swift native/MacApp/ScreenshotPipeline.swift native/MacApp/LibraryOrganization.swift native/MacApp/TopicAgentContext.swift tests/native-storage.swift -o "$APP/Contents/MacOS/StorageTests"
"$APP/Contents/MacOS/StorageTests"
