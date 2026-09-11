#!/bin/bash
# Build on the manual workflow's Linux runner; include corresponding source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/linux-runtime"
OUT="$ROOT/.build/linux-transfer"
WINE="$ROOT/iridium-wine-ios"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
mkdir -p "$WORK" "$OUT/sources"
zsh "$WINE/iridium/ios/build_install_root.sh" --platform linux-x86_64 \
    --build-root "$WORK/build" --install-root "$WORK/install" --jobs "$JOBS"
# This runs in the exact builder image that supplied the copied system libraries.
docker run --rm --platform linux/amd64 \
    -v "$WORK/install:/install:ro" -v "$OUT/sources:/sources" \
    -v "$ROOT/ci/collect-debian-sources.py:/collect.py:ro" \
    iridium-wine-linux-x86_64-builder:local python3 /collect.py /install /sources
zsh "$WINE/iridium/ios/generate_prefix_seed.sh" --output "$WORK/prefix"
zsh "$WINE/iridium/ios/stage_userland.sh" --source-root "$WORK/install" \
    --output-root "$WORK/staged" --seed-output "$WORK/prefix"
zsh "$WINE/iridium/ios/package_userland.sh" --source-root "$WORK/staged" \
    --output "$OUT/wine-userland.tar.zst" --prefix-seed "$WORK/prefix"
# Sources, modifications, and build recipes for this exact revision accompany
# the intermediate binary. Do not upload a bare userland archive.
git -C "$ROOT" archive --format=tar.gz --output="$OUT/sources/iridium-wine-source.tar.gz" HEAD \
    LICENSE LICENSING.md CHANGES-FROM-UPSTREAM.md iridium-wine-ios ci
git -C "$ROOT" rev-parse HEAD > "$OUT/source-revision.txt"
(cd "$OUT" && sha256sum wine-userland.tar.zst source-revision.txt > SHA256SUMS)
