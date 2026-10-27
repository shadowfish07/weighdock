#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/{cache,config,security,ModuleCache} build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
app="${1:-$PWD/build/S400Menu.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp .build/release/S400Menu "$app/Contents/MacOS/S400Menu"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Dependency resource bundles contain privacy manifests; preserve them in the
# standard signed app resource location (these SDKs do not call Bundle.module).
for bundle in .build/release/*.bundle; do
    ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/"
cp Reference/BodyMiScale/LICENSE "$app/Contents/Resources/Licenses/BodyMiScale.txt"
cp Reference/BodyMiScale/NOTICE.md "$app/Contents/Resources/Licenses/BodyMiScale-NOTICE.md"
for vendor in Vendor/*; do
    if [[ -f "$vendor/LICENSE" ]]; then cp "$vendor/LICENSE" "$app/Contents/Resources/Licenses/${vendor:t}.txt"; fi
done
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
echo "$app"
