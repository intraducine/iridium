#!/bin/bash
# Build the pinned Madeira app with Iridium's presentation overlay.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [ "${IRIDIUM_LOCAL_BUILD_LOCKED:-}" != "$PWD" ]; then
  exec python3 ci/local_build_lock.py "$PWD" bash ci/build-madeira-ipa.sh "$@"
fi
output=${1:-"$PWD/.build/madeira-ipa-$(date +%Y%m%d-%H%M%S)"}
mkdir -p .build/local-build-logs
log="$PWD/.build/local-build-logs/madeira-$(date +%Y%m%d-%H%M%S)-$$.log"
exec > >(tee "$log") 2>&1
trap 'status=$?; printf "Build failed (exit %s), line %s. Log: %s\n" "$status" "$LINENO" "$log" >&2; exit "$status"' ERR
printf 'Build log: %s\n' "$log"
python3 ci/local_build_tools.py --madeira --write-env .build/madeira-build-tools.env
source .build/madeira-build-tools.env
if [ -e .git ]; then
  git submodule update --init vendor/Madeira vendor/SameBoy vendor/PPSSPP
  python3 ci/build-ppsspp.py --initialize
  git -C vendor/Madeira submodule update --init FEX wine dxmt madeira-dock
  git -C vendor/Madeira/FEX submodule update --init External/fmt External/range-v3 External/rpmalloc External/unordered_dense External/vixl External/xxhash Source/Common/cpp-optparse
  git -C vendor/Madeira/dxmt submodule update --init --recursive
fi
python3 ci/madeira-frontend.py toolchains
python3 ci/madeira-frontend.py native
python3 ci/madeira-frontend.py windows
# Debug keeps Madeira's guest runtime settings; the final map includes its libraries.
python3 ci/madeira-frontend.py app
python3 ci/package-unsigned-ipa.py \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app "$output"
printf 'IPA: %s/Iridium-unsigned.ipa\n' "$output"
