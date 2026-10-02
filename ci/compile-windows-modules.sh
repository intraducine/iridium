#!/bin/bash
# Run after prepare-native-runtime.sh, using the same source and compiler inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/testrepos/Madeira"
APP="$M/app/Madeira"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"

# Combined Wine builds put dual-architecture archives under aarch64-windows.
# DXMT expects per-architecture directories. Keep its ARM64EC lookup compatible
# with those outputs without changing the archives or rebuilding Wine.
for entry in libs/winecrt0 dlls/ntdll dlls/dbghelp; do
    library="lib${entry##*/}.a"
    base="$M/wine/build-macos/$entry"
    test -s "$base/aarch64-windows/$library" || {
        echo "Missing Wine link input: $entry/aarch64-windows/$library" >&2
        exit 1
    }
    mkdir -p "$base/arm64ec-windows"
    if [ ! -e "$base/arm64ec-windows/$library" ]; then
        ln -s "../aarch64-windows/$library" "$base/arm64ec-windows/$library"
    fi
done

# The ARM64EC FEX DLL is the translator used by x64 games, not the native
# FEX static archive linked into the application.
cmake -S "$M/FEX" -B "$M/FEX/build-arm64ec" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$M/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
    -DFEX_IOS_HOST_BUILD=ON -DTUNE_CPU=generic -DENABLE_LTO=OFF \
    -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_CCACHE=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_WERROR=OFF \
    -DENABLE_STRICT_WERROR=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DENABLE_ZYDIS=OFF -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF \
    -DBUILD_THUNKS=OFF -DBUILD_FEX_LINUX_TESTS=OFF
cmake --build "$M/FEX/build-arm64ec" --target arm64ecfex --parallel "$JOBS"
# FEX places runtime targets in Bin. Preserve the DLL in the component's
# transfer directory before the successful compiler stage is retained.
test -s "$M/FEX/build-arm64ec/Bin/libarm64ecfex.dll"
cp "$M/FEX/build-arm64ec/Bin/libarm64ecfex.dll" \
    "$M/FEX/build-arm64ec/Source/Windows/ARM64EC/libarm64ecfex.dll"


# WoW64 uses its own ARM64 CPU DLL, built from the same corrected FEX source.
cmake -S "$M/FEX" -B "$M/FEX/build-wow64" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$M/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
    -DFEX_IOS_HOST_BUILD=ON -DTUNE_CPU=generic -DENABLE_LTO=OFF \
    -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_CCACHE=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_WERROR=OFF \
    -DENABLE_STRICT_WERROR=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DENABLE_ZYDIS=OFF -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF \
    -DBUILD_THUNKS=OFF -DBUILD_FEX_LINUX_TESTS=OFF
cmake --build "$M/FEX/build-wow64" --target wow64fex --parallel "$JOBS"

# Build the four DXMT PE modules for each Wine architecture. Meson's
# GLOBAL_SOURCE_ROOT is DXMT, while the pinned compiler lives at Madeira root.
for arch in arm64ec aarch64 i386; do
    wine_build="$M/wine/build-macos"
    [ "$arch" != i386 ] || wine_build="$M/wine/build-i386"
    cross="$M/research/dxmt/build-$arch-win.txt"
    configured="$M/research/dxmt/.build-$arch-ci.txt"
    python3 - "$cross" "$configured" "$M" <<'PY'
from pathlib import Path
import sys
source, target, root = map(Path, sys.argv[1:])
text = source.read_text()
# Quote the literal path for Meson's machine-file string syntax.
root_string = str(root).replace('\\', '\\\\').replace("'", "\\'")
text = text.replace('@GLOBAL_SOURCE_ROOT@', root_string)
target.write_text(text)
PY
    build="$M/research/dxmt/build-$arch-ci"
    meson setup "$build" "$M/research/dxmt" --cross-file "$configured" \
        --native-file "$M/research/dxmt/build-osx.txt" --buildtype release \
        -Dwine_build_path="$wine_build" -Dwine_builtin_dll=true \
        -Denable_tests=false -Denable_nvapi=false -Denable_nvngx=false
    meson compile -C "$build" -j "$JOBS"
done

bash "$M/build/madeira-d3d12/build-pe.sh"

# Validate the files consumed by staging before retaining this component.
python3 - "$ROOT" <<'PY_CHECK'
import importlib.util
from pathlib import Path
import sys
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('stage', root / 'ci/stage-windows-runtime.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
madeira = root / 'testrepos/Madeira'
stage.check_pe(madeira / 'FEX/build-arm64ec/Source/Windows/ARM64EC/libarm64ecfex.dll', 'arm64ec')
stage.check_pe(madeira / 'build/madeira-d3d12/out-pe/d3d12.dll', 'arm64ec')
stage.check_pe(madeira / 'FEX/build-wow64/Bin/libwow64fex.dll', 'aarch64')
for arch in (*stage.MACHINES, 'i386'):
    for module in ('d3d11/d3d11', 'dxgi/dxgi', 'winemetal/winemetal', 'd3d10/d3d10core'):
        stage.check_pe(madeira / f'research/dxmt/build-{arch}-ci/src/{module}.dll', arch)
for module in ('d3d9/d3d9', 'd3d9shim/d3d9shim'):
    stage.check_pe(madeira / f'research/dxmt/build-i386-ci/src/{module}.dll', 'i386')
print('Verified both FEX translators, D3D12, and DXMT outputs before retention')
PY_CHECK
