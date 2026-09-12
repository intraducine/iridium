#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/iridium-runtime-sdk"
INPUT="$ROOT/.build/linux-transfer"
cd "$INPUT"
python3 "$ROOT/ci/verify-linux-reuse.py"
# Preserve the SDK's existing host-binary build, including its FEXCore check.
bash "$SDK/scripts/build_runtime_bundle.sh" \
    --bundle-version "ci-$(git -C "$ROOT" rev-parse --short=12 HEAD)" \
    --translator "$ROOT/iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a" \
    --userland "$INPUT/wine-userland.tar.zst" \
    --output-root "$SDK/build/iridium-runtime-base"
RESOURCE="$ROOT/iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime"
if [ -e "$RESOURCE" ]; then
    echo 'Refusing to replace an existing SwiftPM runtime resource' >&2; exit 1
fi
mkdir -p "$(dirname "$RESOURCE")"
cp -R "$SDK/build/iridium-runtime-base" "$RESOURCE"

# Extract after the SwiftPM copy so it does not receive a second userland tree.
# The app's existing stage script reads this canonical extracted location.
python3 "$ROOT/ci/stage-linux-userland.py"
