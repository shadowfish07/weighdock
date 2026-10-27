#!/bin/zsh
# Offline only: does not launch or replace the running application.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/{cache,config,security,ModuleCache} build/evidence
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
python3 Scripts/mihome_reference.py
./Scripts/test.sh
swift build -c release --target MiHomeCompatibility --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swiftc -O -parse-as-library -module-cache-path .build/ModuleCache Sources/MiHomeCompatibility/MiHomeCompatibility.swift Scripts/mihome_optimized_check.swift -o build/evidence/mihome-release-check
./build/evidence/mihome-release-check
echo "Offline report: $PWD/build/evidence/mihome-comparison.json"
