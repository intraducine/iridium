#!/bin/bash
# Run after prepare-native-runtime.sh, using the same source and compiler inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/testrepos/Madeira"
APP="$M/app/Madeira"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"

# The ARM64EC FEX DLL is the translator used by x64 games, not the native
# FEX static archive linked into the application.
cmake -S "$M/FEX" -B "$M/FEX/build-arm64ec" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$M/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DCMAKE_BUILD_TYPE=Release \
    -DFEX_IOS_HOST_BUILD=ON -DTUNE_CPU=generic -DENABLE_LTO=OFF \
    -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_CCACHE=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_WERROR=OFF \
    -DENABLE_STRICT_WERROR=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DENABLE_ZYDIS=OFF -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF \
    -DBUILD_THUNKS=OFF -DBUILD_FEX_LINUX_TESTS=OFF
cmake --build "$M/FEX/build-arm64ec" --target arm64ecfex --parallel "$JOBS"

# Build the four DXMT PE modules for each Wine architecture. Meson's
# GLOBAL_SOURCE_ROOT is DXMT, while the pinned compiler lives at Madeira root.
for arch in arm64ec aarch64; do
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
        -Dwine_build_path="$M/wine/build-macos" -Dwine_builtin_dll=true \
        -Denable_tests=false -Denable_nvapi=false -Denable_nvngx=false
    meson compile -C "$build" -j "$JOBS"
done
