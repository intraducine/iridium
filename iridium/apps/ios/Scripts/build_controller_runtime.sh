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
