#!/bin/sh
set -eu

fex_script="${SRCROOT}/../../../iridium-fex-ios/iridium/ios/build_embedded_translator.sh"

write_output_marker() {
  if [ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
    mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
    printf '%s\n' "$1" > "${SCRIPT_OUTPUT_FILE_0}"
  fi
}

if [ "${IRIDIUM_JIT_REUSE_RUNTIME:-0}" = "1" ]; then
  test "${PLATFORM_NAME}" = "iphoneos" || { echo "error: Existing runtime requires an iPhone build" >&2; exit 1; }
  test -s "${SRCROOT}/../../../iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a" || exit 1
  test -s "${SRCROOT}/../../../iridium-wine-ios/build-iridium-ios/wine-build-iphoneos/artifacts/libiridium-wineserver-ios.a" || exit 1
  echo "Using existing runtime archives for the isolated JIT experiment; sibling builds are untouched"
  exit 0
fi

if [ ! -x "${fex_script}" ]; then
  echo "error: Missing embedded translator build helper at ${fex_script}." >&2
  echo "error: Ensure ../iridium-fex-ios is the Iridium FEX fork and rerun scripts/doctor.sh --bootstrap." >&2
  exit 66
fi

platform=""
case "${PLATFORM_NAME:-}" in
  iphonesimulator)
    platform="simulator"
    ;;
  iphoneos)
    platform="device"
    ;;
  macosx)
    platform="host"
    ;;
esac

if [ -z "${platform}" ]; then
  echo "Skipping embedded translator preparation for PLATFORM_NAME=${PLATFORM_NAME:-unknown}"
  exit 0
fi

fex_root="$(cd "$(dirname "${fex_script}")/../.." && pwd)"
build_root="${fex_root}/build-iridium-ios-${platform}"
archive="${build_root}/artifacts/libiridium-fex-ios-embedded.a"
manifest="${build_root}/iridium-ios-embedded-artifact.txt"

has_prebuilt_translator() {
  [ -s "${archive}" ] &&
    [ -f "${manifest}" ] &&
    grep -qx "MODE=embedded" "${manifest}" &&
    grep -qx "PLATFORM=${platform}" "${manifest}" &&
    grep -qx "TARGET=iridium-fex-ios-embedded" "${manifest}"
}

# Xcode should refresh the archive when the local build toolchain is present.
# A validated prebuilt archive is also a supported input: requiring CMake just
# to link an already-built app made clean Xcode invocations fail needlessly.
if ! command -v cmake >/dev/null 2>&1; then
  if has_prebuilt_translator && [ "${IRIDIUM_REBUILD_EMBEDDED_TRANSLATOR:-0}" != "1" ]; then
    echo "warning: CMake is unavailable; reusing validated ${platform} translator archive at ${archive}." >&2
    write_output_marker "${platform}:prebuilt"
    exit 0
  fi

  echo "error: CMake is required because no valid prebuilt ${platform} translator archive is available." >&2
  echo "error: Install CMake or run ${fex_script} --platform ${platform} before building the app." >&2
  exit 69
fi

"${fex_script}" --platform "${platform}"
write_output_marker "${platform}"
echo "Prepared embedded translator for ${platform}"
