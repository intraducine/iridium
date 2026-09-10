#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_PARENT="$(cd "$ROOT_DIR/.." && pwd)"

mode="all"
if [[ $# -gt 1 ]]; then
    echo "usage: $0 [--bootstrap|--app-build|--all]" >&2
    exit 64
fi

if [[ $# -eq 1 ]]; then
    case "$1" in
        --bootstrap) mode="bootstrap" ;;
        --app-build) mode="app-build" ;;
        --all) mode="all" ;;
        -h|--help)
            cat <<'EOF'
usage: scripts/doctor.sh [--bootstrap|--app-build|--all]

Checks the local Iridium multi-repo workspace before bootstrap, package
resolution, or app runtime staging.
EOF
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 64
            ;;
    esac
fi

failures=()
warnings=()

record_failure() {
    failures+=("$1")
}

record_warning() {
    warnings+=("$1")
}

require_command() {
    local command_name="$1"
    local install_hint="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        record_failure "Missing command '$command_name'. $install_hint"
    fi
}

warn_command() {
    local command_name="$1"
    local install_hint="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        record_warning "Missing optional command '$command_name'. $install_hint"
    fi
}

is_git_checkout() {
    local repo_path="$1"
    [[ -d "$repo_path" ]] && [[ -d "$repo_path/.git" || -f "$repo_path/.git" ]]
}

check_sibling_repos() {
    local required_sibling_repos=(
        "iridium-runtime-sdk"
        "iridium-fex-ios"
        "iridium-wine-ios"
    )

    for repo in "${required_sibling_repos[@]}"; do
        if ! is_git_checkout "$WORKSPACE_PARENT/$repo"; then
            record_failure "Missing sibling repo ../$repo. Clone it next to $ROOT_DIR."
        fi
    done
}

manifest_value() {
    local key="$1"
    local manifest="$2"

    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$manifest"
}

check_fex_manifest() {
    local platform="$1"
    local build_root_name="$2"
    local manifest="$WORKSPACE_PARENT/iridium-fex-ios/$build_root_name/iridium-ios-embedded-artifact.txt"

    if [[ ! -f "$manifest" ]]; then
        record_failure "Missing canonical FEX manifest for $platform at ../iridium-fex-ios/$build_root_name/iridium-ios-embedded-artifact.txt. Run: ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform $platform"
        return
    fi

    local declared_platform
    declared_platform="$(manifest_value PLATFORM "$manifest")"
    if [[ -z "$declared_platform" ]]; then
        record_failure "Canonical FEX manifest for $platform is missing PLATFORM=. Rebuild with: ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform $platform"
    elif [[ "$declared_platform" != "$platform" ]]; then
        record_failure "Canonical FEX manifest $manifest declares PLATFORM=$declared_platform, expected PLATFORM=$platform. Rebuild with: ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform $platform"
    fi
}

check_fex_manifests() {
    if ! is_git_checkout "$WORKSPACE_PARENT/iridium-fex-ios"; then
        return
    fi

    if [[ ! -x "$WORKSPACE_PARENT/iridium-fex-ios/iridium/ios/build_embedded_translator.sh" ]]; then
        record_failure "Missing executable FEX build helper at ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh."
        return
    fi

    check_fex_manifest "host" "build-iridium-ios-host"
    check_fex_manifest "device" "build-iridium-ios-iphoneos"
    check_fex_manifest "simulator" "build-iridium-ios-iphonesimulator"
}

check_runtime_bundle() {
    local bundle_root="$WORKSPACE_PARENT/iridium-runtime-sdk/build/iridium-runtime-base"
    local required_bundle_files=(
        "manifest.json"
        "Runtime/runtime-host.bin"
        "Translator/x64-jit.bin"
        "Userland/wine-userland.tar.zst"
        "Graphics/vkd3d-stack.json"
        "Graphics/ios-presentation-backend.json"
        "Metadata/direct-launch.json"
    )

    if [[ ! -d "$bundle_root" ]]; then
        record_failure "Missing canonical runtime bundle root at ../iridium-runtime-sdk/build/iridium-runtime-base. Rebuild it with ../iridium-runtime-sdk/scripts/build_runtime_bundle.sh --build-from-forks --smoke-check ..."
        return
    fi

    local relative_path
    for relative_path in "${required_bundle_files[@]}"; do
        if [[ ! -f "$bundle_root/$relative_path" ]]; then
            record_failure "Missing runtime bundle artifact ../iridium-runtime-sdk/build/iridium-runtime-base/$relative_path."
        fi
    done
}

check_amethyst_frameworks() {
    local amethyst_root="${IRIDIUM_AMETHYST_ROOT:-$WORKSPACE_PARENT/Amethyst-iOS}"
    local frameworks=(
        "libEGL.framework"
        "libGLESv2.framework"
    )

    local framework
    for framework in "${frameworks[@]}"; do
        if [[ ! -d "$amethyst_root/Natives/resources/Frameworks/$framework" ]]; then
            record_failure "Missing $framework at $amethyst_root/Natives/resources/Frameworks/$framework. Set IRIDIUM_AMETHYST_ROOT or clone Amethyst-iOS next to this workspace."
        fi
    done
}

check_bootstrap_tools() {
    require_command "swift" "Install current Xcode and select its developer tools."
    require_command "xcodebuild" "Install current Xcode and run sudo xcodebuild -license accept."
    require_command "xcodegen" "Install with: brew install xcodegen"
    require_command "zsh" "Install zsh or run this workspace on macOS."
    require_command "python3" "Install Python 3."
    require_command "tar" "Install tar."
    require_command "zstd" "Install zstd."
    warn_command "cmake" "Install CMake before rebuilding the native runtime host."
    warn_command "docker" "Install Docker before rebuilding Wine userland from source forks."
}

check_sibling_repos
check_bootstrap_tools
check_fex_manifests

if [[ "$mode" == "app-build" || "$mode" == "all" ]]; then
    check_runtime_bundle
    check_amethyst_frameworks
fi

if (( ${#warnings[@]} > 0 )); then
    echo "Warnings:"
    printf '  - %s\n' "${warnings[@]}"
fi

if (( ${#failures[@]} > 0 )); then
    echo "Iridium workspace preflight failed:" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
fi

echo "Iridium workspace preflight passed ($mode)."
