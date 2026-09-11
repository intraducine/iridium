#!/bin/bash
# Build FFI and StikJIT from pinned source, never link the opaque vendor archive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/.build/runtime-sources"
STIK="$SOURCE/StikJIT"
IDEVICE="$SOURCE/idevice"
export CARGO_HOME="$ROOT/.build/cargo-home"
export RUSTUP_HOME="$ROOT/.build/rustup"
export CARGO_TARGET_DIR="$ROOT/.build/idevice-target"
export CARGO_BUILD_JOBS="${IRIDIUM_BUILD_JOBS:-2}"
export IPHONEOS_DEPLOYMENT_TARGET=17.4
RUST=1.98.1
command -v rustup >/dev/null
# Removing this exact fetched vendor file is intentional: its source revision
# is unknown. No existing app, certificate, prefix, or development repo is touched.
rm "$STIK/idevice/libidevice_ffi.a"
rustup toolchain install "$RUST" --profile minimal --target aarch64-apple-ios --component rust-src
mkdir -p "$IDEVICE/.cargo"
(cd "$IDEVICE" && cargo +"$RUST" vendor --locked vendor > .cargo/config.toml)
python3 "$ROOT/ci/collect-release-source.py" jit
# Vendor emits a relative directory; do not place machine-specific source paths
# into the corresponding-source archive.
(cd "$IDEVICE" && cargo +"$RUST" build --release --locked --offline \
    --target aarch64-apple-ios -p idevice-ffi)
cp "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a" "$STIK/idevice/"
cp "$IDEVICE/ffi/idevice.h" "$STIK/idevice/idevice.h"
# Preserve the exact crate/source license inventory for the eventual release audit.
(cd "$IDEVICE" && cargo +"$RUST" metadata --locked --offline --format-version=1) | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([{k:p.get(k) for k in ("name","version","license","license_file","source")} for p in d["packages"]],indent=2))' \
    > "$SOURCE/idevice-dependencies.json"
xcodegen generate --spec "$STIK/project.yml"
xcodebuild archive -project "$STIK/StikJIT.xcodeproj" -scheme StikJIT \
    -destination 'generic/platform=iOS' -archivePath "$ROOT/.build/StikJIT" \
    -derivedDataPath "$ROOT/.build/StikJIT-derived" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO GENERATE_INFOPLIST_FILE=YES \
    PRODUCT_BUNDLE_IDENTIFIER=software.iridium.vendor.StikJIT \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= EXPANDED_CODE_SIGN_IDENTITY= PROVISIONING_PROFILE_SPECIFIER=
OUT="$ROOT/iridium/apps/ios/BuiltinJIT/Vendor/StikJIT.xcframework"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -framework "$ROOT/.build/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework" \
    -output "$OUT"
python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
for interface in Path(sys.argv[1]).rglob('*.swiftinterface'):
    interface.write_text(interface.read_text().replace('StikJIT.', ''))
PY
