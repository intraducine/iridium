#!/bin/bash
# Build the native libraries from this checkout. No app build, keychain, or signing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MADEIRA="$ROOT/testrepos/Madeira"
APP="$MADEIRA/app/Madeira"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
export JOBS
case "$JOBS" in ''|*[!0-9]*|0) echo "IRIDIUM_BUILD_JOBS must be a positive integer" >&2; exit 2;; esac
if [ "${1:-}" = --plan ]; then
    printf '%s\n' 'Pinned source inputs and required Git submodules' \
      'GMP -> Nettle -> GnuTLS; FreeType' \
      'LLVM host table generator -> LLVM iOS libraries' \
      'Madeira FEX native archives' \
      'Wine generated headers -> Wine iOS native archives' \
      'Metal shader headers -> DXMT iOS combined archive' \
      'Legacy FEX and embedded Wine server archives' \
      'Source-built media SDK -> media and controller libraries'
    exit 0
fi
[ "$#" -eq 0 ] || { echo "Usage: $0 [--plan]" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
    echo 'Requires an Apple Silicon macOS runner with Xcode 27.' >&2; exit 1;
}
for tool in python3 cmake ninja brew xcrun xcodebuild git; do command -v "$tool" >/dev/null; done
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$MADEIRA/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
python3 "$ROOT/ci/fetch-runtime-inputs.py"

# Use exact gitlink commits. Do not fetch binary test corpora or unrelated modules.
cd "$ROOT"
modules=()
for fork in iridium-fex-ios testrepos/Madeira/FEX; do
    for module in fmt range-v3 rpmalloc unordered_dense vixl xxhash; do
        modules+=("$fork/External/$module")
    done
    modules+=("$fork/Source/Common/cpp-optparse")
done
modules+=(testrepos/Madeira/research/dxmt/include/native/directx)
git submodule update --init --depth 1 -- "${modules[@]}"

bash "$MADEIRA/build/gnutls-ios/build.sh"
bash "$MADEIRA/build/freetype-ios/build.sh"
for name in gnutls hogweed nettle gmp; do
    cp "$MADEIRA/toolchains/gnutls-ios/lib/lib$name.a" "$APP/"
done

# LLVM 15 assumes every Apple target is named Darwin. Apply the documented
# Madeira iOS linker correction to the downloaded source, preserving the patch.
python3 - "$MADEIRA/toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'MATCHES "Darwin"'
if text.count(old) != 2:
    raise SystemExit('Unexpected LLVM source; refusing to apply linker patch')
path.write_text(text.replace(old, 'MATCHES "Darwin|iOS"'))
PY
LLVM="$MADEIRA/toolchains/llvm-project/llvm"
HOST="$MADEIRA/toolchains/llvm-host-build"
IOS="$MADEIRA/toolchains/llvm-ios-build"
llvm_options=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_CURL=OFF \
    -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_RTTI=OFF)
cmake -S "$LLVM" -B "$HOST" "${llvm_options[@]}"
cmake --build "$HOST" --target llvm-tblgen --parallel "$JOBS"
cmake -S "$LLVM" -B "$IOS" "${llvm_options[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF
cmake --build "$IOS" --target LLVMPasses LLVMBitWriter --parallel "$JOBS"

fex_options=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DTUNE_CPU=generic \
    -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF -DBUILD_STEAM_SUPPORT=OFF \
    -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_CCACHE=OFF -DENABLE_LTO=OFF \
    -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF -DENABLE_VIXL_DISASSEMBLER=OFF \
    -DENABLE_VIXL_SIMULATOR=OFF -DENABLE_ZYDIS=OFF -DENABLE_WERROR=OFF \
    -DENABLE_STRICT_WERROR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_GDB_SYMBOLS=OFF)
cmake -S "$MADEIRA/FEX" -B "$MADEIRA/FEX/build-ios" "${fex_options[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0
cmake --build "$MADEIRA/FEX/build-ios" --parallel "$JOBS" \
    --target FEXCore FEXCore_Base fmt xxhash cephes_128bit softfloat_3e

mkdir -p "$MADEIRA/wine/build-macos"
(
    cd "$MADEIRA/wine/build-macos"
    ../configure --enable-win64 --enable-archs=aarch64,arm64ec --without-x --without-freetype --disable-tests
    make -j"$JOBS" include/all tools/winebuild/winebuild
)
for component in wineserver ntdll-unix win32u-unix; do
    bash "$MADEIRA/build/$component/build.sh"
done

xcodebuild -downloadComponent MetalToolchain
SHADERS="$MADEIRA/build/dxmt-ios/shader-headers"
mkdir -p "$SHADERS"
for name in air_msad air_samplepos air_tessellation; do
    xcrun --sdk iphoneos metal -std=metal3.1 --target=air64-apple-ios18.0 \
        -c "$MADEIRA/research/dxmt/src/airconv/shaders/$name.metal" -o "$SHADERS/$name.air"
    xxd -n "$name" -i "$SHADERS/$name.air" "$SHADERS/$name.h"
done
bash "$MADEIRA/build/dxmt-ios/build.sh"
xcrun --sdk iphoneos libtool -static -o "$APP/libdxmt_combined.a" \
    "$MADEIRA/build/dxmt-ios/obj/"*.o "$IOS/lib/"*.a

bash "$ROOT/iridium-fex-ios/iridium/ios/build_embedded_translator.sh" --platform device --jobs "$JOBS"
# The iOS Wine configure step needs host-built Wine tools first.
mkdir -p "$ROOT/iridium-wine-ios/build-iridium-ios/wine-build"
(
    cd "$ROOT/iridium-wine-ios/build-iridium-ios/wine-build"
    ../../configure --enable-win64 --without-x --without-freetype --disable-tests
    make -j"$JOBS" include/all tools/winebuild/all tools/widl/all tools/wrc/all tools/winegcc/all
)
zsh "$ROOT/iridium-wine-ios/iridium/ios/build_install_root.sh" \
    --platform device --embedded-server-only --jobs "$JOBS"

test -s "$ROOT/iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a"
sh "$ROOT/iridium/apps/ios/Scripts/build_media_runtime.sh"
sh "$ROOT/iridium/apps/ios/Scripts/build_controller_runtime.sh"

# Fail on absent/empty output and non-arm64 archives before app generation.
for name in wineserver ntdll_unix win32u_unix dxmt_combined gnutls hogweed nettle gmp; do
    test -s "$APP/lib$name.a"
    xcrun lipo -verify_arch arm64 "$APP/lib$name.a"
done
printf '%s\n' 'Native libraries prepared. Windows modules, prefix, and legacy bundle still require their preparation stages.'
