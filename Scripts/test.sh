#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/{cache,config,security,ModuleCache}
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
developer="$(xcode-select -p)"
# CLT and full Xcode place Swift Testing in different framework directories.
frameworks=""
for candidate in "$developer/Library/Developer/Frameworks" "$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
    if [[ -d "$candidate/Testing.framework" ]]; then frameworks="$candidate"; break; fi
done
if [[ -z "$frameworks" ]]; then
    print -u2 "Swift Testing.framework was not found; select a Swift 6 CLT or Xcode toolchain."
    exit 1
fi
flags=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
for libraries in "$developer/Library/Developer/usr/lib" "$developer/Platforms/MacOSX.platform/Developer/usr/lib"; do
    if [[ -d "$libraries" ]]; then flags+=(-Xlinker -rpath -Xlinker "$libraries"); fi
done
swift test --disable-xctest --enable-swift-testing "${flags[@]}" --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
