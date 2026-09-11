#!/bin/bash
# Build the legacy EGL/GLES frameworks from ANGLE source, not Amethyst binaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/.build/runtime-sources/angle"
DEPOT="$ROOT/.build/depot_tools"
ANGLE_REV=6024e9c05548480c3b2ea42836a112509a549a95
DEPOT_REV=6794dd02d7ba80c074d2ff0d294a32b9c5dc0112
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
# Fail instead of replacing a developer's existing checkout.
for target in "$SOURCE" "$DEPOT"; do
    [ ! -e "$target" ] || { echo "Existing source directory: $target" >&2; exit 1; }
    mkdir -p "$target"
done
git -C "$SOURCE" init
git -C "$SOURCE" fetch --depth 1 https://github.com/google/angle.git "$ANGLE_REV"
git -C "$SOURCE" checkout --detach FETCH_HEAD
git -C "$DEPOT" init
git -C "$DEPOT" fetch --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_REV"
git -C "$DEPOT" checkout --detach FETCH_HEAD
export DEPOT_TOOLS_UPDATE=0
export PATH="$DEPOT:$PATH"
cd "$SOURCE"
cat > .gclient <<'CONFIG'
solutions = [{
    "name": ".", "url": "https://chromium.googlesource.com/angle/angle.git",
    "managed": False, "deps_file": "DEPS",
    "custom_vars": {
        "checkout_angle_internal": False,
        "checkout_angle_restricted_traces": False,
        "checkout_angle_mesa": False,
    },
}]
target_os = ["ios"]
CONFIG
gclient sync --no-history --shallow
gclient revinfo --actual > "$ROOT/.build/runtime-sources/angle-revisions.txt"
gn gen out/iridium-ios --args='target_os="ios" target_cpu="arm64" target_environment="device" use_system_xcode=true ios_enable_code_signing=false ios_deployment_target="18.0" is_debug=false is_component_build=false angle_build_all=false angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false angle_enable_null=false symbol_level=0'
ninja -C out/iridium-ios -j "$JOBS" libEGL libGLESv2
DEST="$ROOT/Amethyst-iOS/Natives/resources/Frameworks"
mkdir -p "$DEST"
for name in libEGL libGLESv2; do
    test -s "out/iridium-ios/$name.framework/$name"
    xcrun lipo -verify_arch arm64 "out/iridium-ios/$name.framework/$name"
    [ ! -e "$DEST/$name.framework" ] || { echo 'Existing graphics framework; refusing replacement' >&2; exit 1; }
    cp -R "out/iridium-ios/$name.framework" "$DEST/"
done
# Use ANGLE's full license text, and retain every source dependency's own notice.
cp LICENSE "$ROOT/testrepos/Madeira/app/Madeira/legal/ANGLE-LICENSE.txt"
