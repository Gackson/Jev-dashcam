#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -parse-as-library -module-cache-path build/module-cache native/WindowExclusion.swift native/MacApp/Store.swift native/MacApp/ScreenshotPipeline.swift native/MacApp/LibraryOrganization.swift native/MacApp/TopicAgentContext.swift tests/native-context.swift -o build/native-context-tests
./build/native-context-tests
swiftc -parse-as-library -module-cache-path build/module-cache native/WindowExclusion.swift native/MacApp/Store.swift native/MacApp/ScreenshotPipeline.swift native/MacApp/LibraryOrganization.swift native/MacApp/TopicAgentContext.swift tests/native-performance.swift -o build/native-performance-tests
./build/native-performance-tests
swiftc -parse-as-library -module-cache-path build/module-cache native/WindowExclusion.swift tests/native-exclusions.swift -o build/native-exclusions-tests
./build/native-exclusions-tests
