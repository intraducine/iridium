#!/bin/bash
# Builds a minimal Wine prefix snapshot for the iOS app to extract on first launch.
#
# Runs `wineboot --init` on macOS, then strips everything we already ship in the
# app bundle (PE binaries, NLS, fonts). What's left is the registry + directory
# skeleton — the iOS app symlinks bundle resources on top after extraction.
#
# Output: app/Madeira/prefix-template.tar.gz

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$REPO_ROOT/app/Madeira/prefix-template.tar.gz"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/madeira-prefix-build.XXXXXX")"
touch "$WORK_DIR/.iridium-prefix-build"
trap 'rm -rf "$WORK_DIR"' EXIT
PREFIX="$WORK_DIR/prefix"

WINE_BIN="${WINE:-/opt/homebrew/bin/wine}"
WINEBOOT_BIN="${WINEBOOT:-/opt/homebrew/bin/wineboot}"

if [[ ! -x "$WINE_BIN" ]]; then
    echo "error: wine not found at $WINE_BIN (override with WINE=...)" >&2
    exit 1
fi

echo "==> Running wineboot --init in $PREFIX"
WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=" \
    "$WINEBOOT_BIN" --init
if [[ -n "${WINESERVER:-}" ]]; then
    WINEPREFIX="$PREFIX" "$WINESERVER" -w
fi

if [[ ! -f "$PREFIX/.update-timestamp" ]]; then
    echo "error: wineboot did not produce .update-timestamp" >&2
    exit 1
fi

echo "==> Removing build-host identity and host links"
python3 "$SCRIPT_DIR/../../../ci/sanitize-prefix.py" "$PREFIX" "$(id -un)"

echo "==> Stripping files shipped in app bundle"
# Drop all PE binaries (iOS app symlinks aarch64 versions from bundle)
find "$PREFIX/drive_c" -type f \( \
    -name "*.dll" -o -name "*.exe" -o -name "*.drv" -o -name "*.sys" \
    -o -name "*.acm" -o -name "*.cpl" -o -name "*.tlb" -o -name "*.ax" \
    -o -name "*.ocx" -o -name "*.mui" -o -name "*.rll" \
    \) -delete

# NLS files are bundled separately in app/Madeira/nls/
find "$PREFIX/drive_c/windows/system32" -maxdepth 1 -name "*.nls" -delete 2>/dev/null || true
rm -rf "$PREFIX/drive_c/windows/globalization"

# Heavy trees we don't need for Phase 3A (cmd.exe / single-exe games)
rm -rf "$PREFIX/drive_c/windows/winsxs"
rm -rf "$PREFIX/drive_c/windows/Microsoft.NET"
rm -rf "$PREFIX/drive_c/windows/resources"
rm -rf "$PREFIX/drive_c/windows/system32/catroot"
rm -rf "$PREFIX/drive_c/windows/system32/driverstore"
rm -rf "$PREFIX/drive_c/windows/system32/gecko"
rm -rf "$PREFIX/drive_c/windows/system32/mui"
rm -rf "$PREFIX/drive_c/windows/system32/Speech"
rm -rf "$PREFIX/drive_c/windows/system32/winmetadata"
rm -rf "$PREFIX/drive_c/windows/system32/WindowsPowerShell"
rm -rf "$PREFIX/drive_c/windows/syswow64"

# dosdevices symlinks get recreated by the iOS app (z: -> / is wrong on iOS)
rm -rf "$PREFIX/dosdevices"

echo "==> Post-strip contents:"
du -sh "$PREFIX"
find "$PREFIX" -maxdepth 3 -type d | sort

echo "==> Creating tarball: $OUTPUT"
tar -C "$WORK_DIR" -czf "$OUTPUT" prefix
ls -lh "$OUTPUT"

echo "==> Done."
