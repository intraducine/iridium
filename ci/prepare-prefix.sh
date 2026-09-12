#!/bin/bash
# Initialize a win64 prefix on Linux from the same Wine source shipped on iOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/prefix-wine"
OUT="$ROOT/.build/prefix-transfer"
mkdir -p "$BUILD" "$OUT"
cd "$BUILD"
"$ROOT/testrepos/Madeira/wine/configure" --enable-win64 --without-x --without-freetype --disable-tests
make -j"${IRIDIUM_BUILD_JOBS:-2}"
WINE="$BUILD/loader/wine" WINEBOOT="$ROOT/ci/wineboot-from-build.sh" \
WINEBOOT_PE="$BUILD/programs/wineboot/x86_64-windows/wineboot.exe" \
WINESERVER="$BUILD/server/wineserver" \
    timeout 180 bash "$ROOT/testrepos/Madeira/scripts/build-prefix-snapshot.sh"
cp "$ROOT/testrepos/Madeira/app/Madeira/prefix-template.tar.gz" "$OUT/"
git -C "$ROOT" rev-parse HEAD > "$OUT/source-revision.txt"
(cd "$OUT" && sha256sum prefix-template.tar.gz source-revision.txt > SHA256SUMS)
