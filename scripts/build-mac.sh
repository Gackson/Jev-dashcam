#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Dashcam.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
ARCH=$(uname -m)
# TCC identifies updates by their signing requirement. Ad-hoc signatures bind it
# to a changing binary hash, so a successful rebuild can invalidate permission.
if [[ -z "${JEV_SIGNING_IDENTITY:-}" ]]; then
  IDENTITIES=$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}) ".*$/\1/p')
  if [[ $(printf '%s\n' "$IDENTITIES" | awk 'NF {count++} END {print count+0}') != 1 ]]; then
    echo 'Set JEV_SIGNING_IDENTITY to a stable code-signing certificate (security find-identity -v -p codesigning). Ad-hoc signing is not supported because it breaks recording permissions after updates.' >&2
    exit 1
  fi
  JEV_SIGNING_IDENTITY="$IDENTITIES"
fi
if [[ "$JEV_SIGNING_IDENTITY" == '-' ]]; then
  echo 'A stable signing certificate is required; ad-hoc signing invalidates recording permissions after updates.' >&2
  exit 1
fi
# Prefer a self-contained runtime: Homebrew's node depends on external dylibs.
if [[ -n "${JEV_NODE_BINARY:-}" ]]; then
  NODE_SOURCE="$JEV_NODE_BINARY"
elif [[ -x "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node" ]]; then
  NODE_SOURCE="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
else
  NODE_SOURCE=$(command -v node)
fi
if otool -L "$NODE_SOURCE" | tail -n +2 | awk '{print $1}' | rg -v '^(/usr/lib/|/System/Library/)' >/dev/null; then
  echo 'A standalone Node.js runtime is required. Set JEV_NODE_BINARY to an official nodejs.org macOS binary (Node 22.13+).' >&2
  exit 1
fi
"$NODE_SOURCE" -e 'require("node:sqlite")'
mkdir -p "$CONTENTS/MacOS" "$RESOURCES/service/build" "$RESOURCES/runtime" build/module-cache
APP_VERSION=$("$NODE_SOURCE" -p 'require("./package.json").version')
NODE_VERSION=$("$NODE_SOURCE" --version)
NODE_LICENSE="build/node-${NODE_VERSION}-LICENSE.txt"
if [[ ! -s "$NODE_LICENSE" ]]; then
  curl -fsSL --max-time 30 "https://raw.githubusercontent.com/nodejs/node/${NODE_VERSION}/LICENSE" -o "$NODE_LICENSE"
fi
cp "$NODE_LICENSE" "$RESOURCES/runtime/LICENSE.txt"
bash scripts/build-native.sh
swiftc -parse-as-library -O -target "$ARCH-apple-macos14.0" -module-cache-path build/module-cache native/WindowExclusion.swift native/MacApp/*.swift -o "$CONTENTS/MacOS/JevDashcam"
cp "$NODE_SOURCE" "$RESOURCES/runtime/node"
cp storage-migration.mjs server.mjs core.mjs capture-migration.mjs window-exclusions.mjs capture-policy.mjs legacy-project-migration.mjs "$RESOURCES/service/"
cp build/jev-capture "$RESOURCES/service/build/"
# No .env, screenshots or user database are included in the distributable.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Dashcam</string>
<key>CFBundleDisplayName</key><string>Dashcam</string>
<key>CFBundleIdentifier</key><string>ai.jevnote.mac</string>
<key>CFBundleExecutable</key><string>JevDashcam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
<key>NSScreenCaptureUsageDescription</key><string>Dashcam 识别当前窗口的文字，整理到你关注的话题。截图仅保存在本机。</string>
</dict></plist>
PLIST
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$APP_VERSION" "$CONTENTS/Info.plist"
bash scripts/build-icon.sh "$RESOURCES"
codesign --force --sign "$JEV_SIGNING_IDENTITY" --identifier ai.jevnote.runtime "$RESOURCES/runtime/node"
codesign --force --sign "$JEV_SIGNING_IDENTITY" --identifier ai.jevnote.capture "$RESOURCES/service/build/jev-capture"
codesign --force --sign "$JEV_SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
