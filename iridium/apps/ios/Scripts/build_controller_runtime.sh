#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
for arch in x64 x86 arm64ec; do
  compiler=x86_64-w64-mingw32-gcc
  [ "$arch" != x86 ] || compiler=i686-w64-mingw32-gcc
  if [ "$arch" = arm64ec ]; then
    compiler="$root/../../../testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang"
  fi
  mkdir -p "$root/ControllerRuntime/$arch"
  "$compiler" -shared -O2 -static-libgcc "$root/MadeiraSupport/xinput.c" \
    "$root/MadeiraSupport/xinput.def" -o "$root/ControllerRuntime/$arch/xinput.dll"
done
# The service manager and MSI host are native ARM64. Start the installer
# session natively; Wine selects WoW64 or ARM64EC for each child executable.
compiler="$root/../../../testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-clang"
mkdir -p "$root/ControllerRuntime/aarch64"
"$compiler" -O2 -municode -static-libgcc "$root/MadeiraSupport/prerequisites.c" \
  -o "$root/ControllerRuntime/aarch64/iridium-prerequisites.exe" -ladvapi32
