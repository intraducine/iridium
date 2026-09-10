#!/bin/sh
set -eu

wine_root="${SRCROOT}/../../../iridium-wine-ios"

case "${PLATFORM_NAME:-}" in
  iphoneos)
    platform="device"
    build_root="${wine_root}/build-iridium-ios/wine-build-iphoneos"
    ;;
  iphonesimulator)
    platform="simulator"
    build_root="${wine_root}/build-iridium-ios/wine-build-iphonesimulator"
    ;;
  *)
    echo "Skipping embedded Wine server preparation for PLATFORM_NAME=${PLATFORM_NAME:-unknown}"
    exit 0
    ;;
esac

archive="${build_root}/artifacts/libiridium-wineserver-ios.a"
build_helper="${wine_root}/iridium/ios/build_embedded_wineserver.sh"
forward_object="${build_root}/server/iridium_embedded_wineserver.o"
embedded_source="${wine_root}/iridium/ios/src/embedded_wineserver.c"
embedded_header="${wine_root}/iridium/ios/include/iridium_wine_ios_embedded_server.h"

if [ "${IRIDIUM_JIT_REUSE_RUNTIME:-0}" = "1" ]; then
  test "${PLATFORM_NAME}" = "iphoneos" || { echo "error: Existing runtime requires an iPhone build" >&2; exit 1; }
  test -s "${SRCROOT}/../../../iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a" || exit 1
  test -s "${SRCROOT}/../../../iridium-wine-ios/build-iridium-ios/wine-build-iphoneos/artifacts/libiridium-wineserver-ios.a" || exit 1
  echo "Using existing runtime archives for the isolated JIT experiment; sibling builds are untouched"
  exit 0
fi

if [ ! -f "${build_root}/Makefile" ]; then
  echo "error: Missing configured native ${platform} Wine server build at ${build_root}." >&2
  echo "error: Configure it with ${wine_root}/iridium/ios/build_install_root.sh --platform ${platform} --embedded-server-only." >&2
  exit 66
fi

# Wine's server-facing source includes the Iridium implementation from another
# directory. Its generated Makefile does not track that transitive include, so
# explicitly invalidate the forwarding object when the implementation changes.
if [ ! -f "${forward_object}" ] || [ "${embedded_source}" -nt "${forward_object}" ] || [ "${embedded_header}" -nt "${forward_object}" ]; then
  rm -f "${forward_object}"
fi

"${build_helper}" --build-root "${build_root}" --output "${archive}"

if ! xcrun lipo -info "${archive}" 2>/dev/null | grep -q 'arm64'; then
  echo "error: Embedded Wine server archive is not arm64: ${archive}." >&2
  exit 66
fi

if [ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
  mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
  printf '%s\n' "${platform}" > "${SCRIPT_OUTPUT_FILE_0}"
fi

echo "Prepared native embedded Wine server for ${platform}"
