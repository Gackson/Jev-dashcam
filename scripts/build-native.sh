#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -parse-as-library -O -module-cache-path build/module-cache native/WindowExclusion.swift native/Capture.swift -o build/jev-capture
echo 'Native capture helper built: build/jev-capture'
