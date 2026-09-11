#!/bin/bash
# Build only the iPhone slice. Cerbero owns codec sources, patches and packaging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERBERO="$ROOT/.build/runtime-sources/cerbero"
CONFIG="$ROOT/.build/cerbero-ci.cbc"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
python3 - "$CONFIG" "$ROOT/.build/cerbero-home" "$JOBS" <<'PY'
from pathlib import Path
import platform
import sys
Path(sys.argv[1]).write_text('home_dir = ' + repr(sys.argv[2]) + '\nnum_of_cpus = ' + sys.argv[3] + '\n')
# Cerbero loads this for its separate host-tools configuration too. These
# tools run only on the build host; the iPhone deployment target is unchanged.
host_config = Path.home() / '.cerbero' / 'cerbero.cbc'
host_config.parent.mkdir(exist_ok=True)
with host_config.open('x') as config:
    config.write('min_osx_sdk_version = ' + repr(platform.mac_ver()[0]) + '\n')
PY
cd "$CERBERO"
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    bootstrap --assume-yes --jobs "$JOBS"
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    package gstreamer-1.0 --artifact=xcframework --jobs "$JOBS"
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    bundle-source gstreamer-1.0 --offline
mkdir -p "$ROOT/.build/corresponding-source"
cp dist/cerbero-1.28.6.tar.xz "$ROOT/.build/corresponding-source/"
python3 - "$CERBERO" "$ROOT/iridium/apps/ios/.build/media-sdk" <<'PY'
from pathlib import Path
import sys, tarfile
source, output = map(Path, sys.argv[1:])
archives = list(source.glob('gstreamer-1.0-1.28.6-ios-arm64.xcframework.tar.xz'))
if len(archives) != 1:
    raise SystemExit('Expected the Cerbero 1.28.6 iOS ARM64 XCFramework package')
if output.exists():
    raise SystemExit('Refusing to replace an existing media SDK')
output.mkdir(parents=True)
with tarfile.open(archives[0]) as archive:
    archive.extractall(output, filter='data')
if not (output / 'GStreamer.xcframework/ios-arm64/libGStreamer.a').is_file():
    raise SystemExit('Cerbero output has an unexpected framework layout')
PY
