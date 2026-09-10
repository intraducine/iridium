#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Running workspace preflight"
"$ROOT_DIR/scripts/doctor.sh" --bootstrap

echo "==> Checking Swift toolchain"
if ! swift --version >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Swift tooling is present but not ready.
Resolve local prerequisites first:
  sudo xcodebuild -license accept
EOF
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    cat >&2 <<'EOF'
xcodegen is not installed.
Resolve local prerequisites first:
  sudo xcodebuild -license accept
  brew install xcodegen
EOF
    exit 1
fi

echo "==> Running Swift package tests"
(cd "$ROOT_DIR" && swift test)

echo "==> Generating Xcode project"
"$ROOT_DIR/scripts/generate-project.sh"

echo "Bootstrap completed."
