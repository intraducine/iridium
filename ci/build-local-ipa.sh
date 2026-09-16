#!/bin/bash
# Reuse staged dependencies and Xcode's incremental build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
python3 ci/check-local-runtime-provenance.py
python3 ci/check-ipa-prerequisites.py
runtime_resources=iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime
mkdir -p "$runtime_resources"
ditto iridium-runtime-sdk/build/iridium-runtime-base "$runtime_resources/iridium-runtime-base"
python3 ci/prepare-stikjit-interface.py
xcodegen generate --spec iridium/apps/ios/stikjit.yml
xcodebuild -project iridium/apps/ios/IridiumStikJIT.xcodeproj \
  -scheme Iridium -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/local-ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= EXPANDED_CODE_SIGN_IDENTITY= \
  PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= \
  IPHONEOS_DEPLOYMENT_TARGET=27.0 LD_GENERATE_MAP_FILE=YES build
app=.build/local-ipa/Build/Products/Release-iphoneos/Iridium.app
objcopy="$(brew --prefix llvm)/bin/llvm-objcopy"
echo 'Removing Windows debug sections from the packaged app copy.'
for arch in arm64ec aarch64; do
  while IFS= read -r -d '' module; do
    if [ "$(head -c 2 "$module")" = MZ ]; then
      "$objcopy" --strip-debug "$module"
    fi
  done < <(find "$app/$arch-windows" -type f -print0)
done
python3 ci/check-ipa-prerequisites.py --package
output=$(mktemp -d "$PWD/.build/local-ipa-output.XXXXXX")
python3 ci/package-unsigned-ipa.py \
  "$app" "$output"
printf 'IPA: %s/Iridium-unsigned.ipa\n' "$output"
