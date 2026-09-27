#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -parse-as-library -O -target "$(uname -m)-apple-macos14.0" -module-cache-path build/module-cache native/WindowExclusion.swift native/Capture.swift -o build/jev-capture
echo 'Native capture helper built: build/jev-capture'
