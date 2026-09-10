#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_PARENT="$(cd "$ROOT/.." && pwd)"

REPOS=(
  "iridium"
  "iridium-runtime-sdk"
  "iridium-fex-ios"
  "iridium-wine-ios"
)

failures=0

record_failure() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

record_warning() {
  echo "warning: $*" >&2
}

check_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    record_warning "Missing optional validation tool: $command_name"
  fi
}

echo "== Iridium workspace audit =="
echo "workspace: $WORKSPACE_PARENT"

for repo in "${REPOS[@]}"; do
  repo_root="$WORKSPACE_PARENT/$repo"
  echo
  echo "== $repo =="
  if [[ ! -d "$repo_root/.git" ]]; then
    record_failure "Missing git repository at $repo_root"
    continue
  fi

  git -C "$repo_root" status --short --branch

  dirty_count="$(git -C "$repo_root" status --porcelain | wc -l | tr -d ' ')"
  if [[ "$dirty_count" != "0" ]]; then
    record_warning "$repo has uncommitted changes"
  fi
done

echo
echo "== Tooling =="
check_command swift
check_command cmake
check_command xcodebuild
check_command xcodegen
check_command docker
check_command codedb

echo
echo "== Generated artifact checks =="
wine_generated="$WORKSPACE_PARENT/iridium-wine-ios/iridium/ios"
if git -C "$WORKSPACE_PARENT/iridium-wine-ios" ls-files 'iridium/ios/build.log' 'iridium/ios/build/*' 'iridium/ios/test-tools/**/*.o' | grep -q .; then
  record_failure "iridium-wine-ios still tracks generated iridium/ios build outputs"
else
  echo "ok: iridium-wine-ios generated build outputs are not tracked"
fi

if [[ -f "$wine_generated/build.log" || -d "$wine_generated/build" ]]; then
  record_warning "local Wine iOS build outputs are present under $wine_generated"
fi

echo
echo "== Canonical embedded FEX manifests =="
for platform in host iphoneos iphonesimulator; do
  manifest="$WORKSPACE_PARENT/iridium-fex-ios/build-iridium-ios-$platform/iridium-ios-embedded-artifact.txt"
  if [[ -f "$manifest" ]]; then
    echo "ok: $manifest"
  else
    record_warning "Missing $manifest"
  fi
done

echo
if [[ "$failures" -gt 0 ]]; then
  echo "audit failed with $failures blocking issue(s)"
  exit 1
fi

echo "audit completed with no blocking issues"
