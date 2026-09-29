#!/bin/bash
# Run after prepare-native-runtime.sh, using the same source and compiler inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/testrepos/Madeira"
APP="$M/app/Madeira"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"

python3 "$ROOT/ci/stage-windows-runtime.py" "$M/wine/build-macos" "$APP" "$M/wine"
cp "$M/FEX/build-arm64ec/Source/Windows/ARM64EC/libarm64ecfex.dll" "$APP/arm64ec-windows/xtajit64.dll"
python3 "$ROOT/ci/stage-windows-runtime.py" --i386 "$M/wine/build-i386" "$APP"
cp "$M/FEX/build-wow64/Bin/libwow64fex.dll" "$APP/aarch64-windows/xtajit.dll"
for arch in arm64ec aarch64 i386; do
    for module in d3d11/d3d11 dxgi/dxgi winemetal/winemetal d3d10/d3d10core; do
        cp "$M/research/dxmt/build-$arch-ci/src/$module.dll" "$APP/$arch-windows/"
    done
done

cp "$M/research/dxmt/build-i386-ci/src/d3d9shim/d3d9shim.dll" "$APP/i386-windows/d3d9.dll"
cp "$M/research/dxmt/build-i386-ci/src/d3d9shim/d3d9shim.dll" "$APP/i386-windows/d3d9shim.dll"
cp "$M/research/dxmt/build-i386-ci/src/d3d9/d3d9.dll" "$APP/i386-windows/d3d9-emulated.dll"

cp "$M/build/madeira-d3d12/out-pe/d3d12.dll" "$APP/arm64ec-windows/d3d12.dll"
bash "$M/build/madeira-d3d12/fetch-converter.sh"

# Wine's build-tree PE modules contain DWARF debug sections. They are useful to
# developers but are not read by the Windows runtime, and retaining them makes
# the app bundle several times larger. Strip debug data only; keep PE code,
# exports, resources, relocations, and unwind information intact.
objcopy="$(command -v llvm-objcopy)"
for arch in arm64ec aarch64 i386; do
    while IFS= read -r -d '' module; do
        if [ "$(head -c 2 "$module")" = "MZ" ]; then
            "$objcopy" --strip-debug "$module"
        fi
    done < <(find "$APP/$arch-windows" -type f -print0)
done

cp "$ROOT/.build/prefix-transfer/prefix-template.tar.gz" "$APP/prefix-template.tar.gz"
python3 "$ROOT/ci/stage-windows-runtime.py" --check "$APP"
