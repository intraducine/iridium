#!/bin/bash
# Run after prepare-native-runtime.sh, using the same source and compiler inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/testrepos/Madeira"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"

# The Unix media backend is built for iOS by prepare-native-runtime.sh.
# Wine's default target also builds a macOS backend requiring host GStreamer.
TARGETS=()
while IFS= read -r target; do
    TARGETS+=("$target")
done < <(grep -oE '^(dlls|programs)/[^/]+/(aarch64|arm64ec)-windows/[^/ :]+' "$M/wine/build-macos/Makefile" \
    | grep -E '\.(com|msstyles|dll|exe|drv|sys|acm|cpl|tlb|ax|ocx|mui|rll)$' | sort -u)
if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo 'Wine Makefile has no ARM64 or ARM64EC Windows module targets' >&2
    exit 1
fi
make -C "$M/wine/build-macos" -j"$JOBS" nls/all fonts/all "${TARGETS[@]}"

# Retain the separate 32-bit compiler tree before bundle staging.
JOBS="$JOBS" COMPILE_ONLY=1 bash "$M/build/wine-i386/build.sh"

# DXMT needs these import archives even when no Wine program imports them.
make -C "$M/wine/build-i386" -j"$JOBS" \
    libs/winecrt0/i386-windows/libwinecrt0.a \
    dlls/ntdll/i386-windows/libntdll.a \
    dlls/dbghelp/i386-windows/libdbghelp.a tools/winebuild/winebuild
