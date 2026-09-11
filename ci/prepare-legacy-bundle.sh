#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/iridium-runtime-sdk"
INPUT="$ROOT/.build/linux-transfer"
cd "$INPUT"
shasum -a 256 -c SHA256SUMS
[ "$(cat source-revision.txt)" = "$(git -C "$ROOT" rev-parse HEAD)" ] || {
    echo 'Linux userland came from a different source revision' >&2; exit 1;
}
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
