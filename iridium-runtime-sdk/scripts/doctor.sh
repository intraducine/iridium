#!/bin/bash

set -euo pipefail

SCRIPT_PATH="$0"
if [[ -n "${BASH_VERSION:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
WORKSPACE_PARENT="$(cd "$ROOT/.." && pwd)"

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
  local hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    record_failure "Missing command '$command_name'. $hint"
  fi
}

warn_command() {
  local command_name="$1"
  local hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    record_warning "Missing optional command '$command_name'. $hint"
  fi
}

manifest_value() {
  local key="$1"
  local manifest="$2"
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$manifest"
}

check_manifest() {
  local platform="$1"
  local build_root_name="$2"
  local manifest="$WORKSPACE_PARENT/iridium-fex-ios/$build_root_name/iridium-ios-embedded-artifact.txt"

  if [[ ! -f "$manifest" ]]; then
    record_warning "Missing FEX $platform manifest at ../iridium-fex-ios/$build_root_name/iridium-ios-embedded-artifact.txt. Run ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform $platform before Swift package resolution."
    return
  fi

  local declared_platform
  declared_platform="$(manifest_value PLATFORM "$manifest")"
  if [[ "$declared_platform" != "$platform" ]]; then
    record_warning "FEX manifest $manifest declares PLATFORM=${declared_platform:-<missing>}, expected $platform."
  fi
}

require_command "python3" "Install Python 3."
require_command "tar" "Install tar."
require_command "zstd" "Install zstd."

if ! command -v cmake >/dev/null 2>&1 && ! command -v swift >/dev/null 2>&1; then
  record_failure "Missing both 'cmake' and 'swift'. At least one is required to build runtime-host.bin."
fi

warn_command "zsh" "Required when building Wine userland from the sibling fork."
warn_command "docker" "Required for the default linux-x86_64 Wine userland build."

if [[ ! -x "$WORKSPACE_PARENT/iridium-fex-ios/iridium/ios/build_embedded_translator.sh" ]]; then
  record_failure "Missing executable FEX build helper at ../iridium-fex-ios/iridium/ios/build_embedded_translator.sh."
else
  check_manifest "host" "build-iridium-ios-host"
  check_manifest "device" "build-iridium-ios-iphoneos"
  check_manifest "simulator" "build-iridium-ios-iphonesimulator"
fi

if [[ ! -d "$WORKSPACE_PARENT/iridium-wine-ios/iridium/ios" ]]; then
  record_failure "Missing sibling Wine fork at ../iridium-wine-ios."
fi

if (( ${#warnings[@]} > 0 )); then
  echo "Warnings:"
  printf '  - %s\n' "${warnings[@]}"
fi

if (( ${#failures[@]} > 0 )); then
  echo "Iridium runtime SDK preflight failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "Iridium runtime SDK preflight passed."
