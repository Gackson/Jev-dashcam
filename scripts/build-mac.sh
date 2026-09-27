#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Jev-dashcam.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
ARCH=$(uname -m)
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
NODE_VERSION=$("$NODE_SOURCE" --version)
NODE_LICENSE="build/node-${NODE_VERSION}-LICENSE.txt"
if [[ ! -s "$NODE_LICENSE" ]]; then
  curl -fsSL --max-time 30 "https://raw.githubusercontent.com/nodejs/node/${NODE_VERSION}/LICENSE" -o "$NODE_LICENSE"
fi
cp "$NODE_LICENSE" "$RESOURCES/runtime/LICENSE.txt"
bash scripts/build-native.sh
swiftc -parse-as-library -O -target "$ARCH-apple-macos14.0" -module-cache-path build/module-cache native/WindowExclusion.swift native/MacApp/*.swift -o "$CONTENTS/MacOS/JevDashcam"
cp "$NODE_SOURCE" "$RESOURCES/runtime/node"
cp server.mjs core.mjs capture-migration.mjs window-exclusions.mjs capture-policy.mjs legacy-project-migration.mjs "$RESOURCES/service/"
cp build/jev-capture "$RESOURCES/service/build/"
# No .env, screenshots or user database are included in the distributable.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Jev-dashcam</string>
<key>CFBundleDisplayName</key><string>Jev-dashcam</string>
<key>CFBundleIdentifier</key><string>ai.jevnote.mac</string>
<key>CFBundleExecutable</key><string>JevDashcam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
<key>NSScreenCaptureUsageDescription</key><string>Jev-dashcam 识别当前窗口的文字，整理到你关注的话题。截图仅保存在本机。</string>
</dict></plist>
PLIST
swift -module-cache-path build/module-cache scripts/draw-icon.swift build/AppIcon.png
mkdir -p build/AppIcon.iconset
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" build/AppIcon.png --out "build/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" build/AppIcon.png --out "build/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
"$NODE_SOURCE" scripts/pack-icon.mjs "$RESOURCES/AppIcon.icns"
codesign --force --sign - "$RESOURCES/runtime/node"
codesign --force --sign - "$RESOURCES/service/build/jev-capture"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
