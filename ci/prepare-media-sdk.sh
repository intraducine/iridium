#!/bin/bash
# Build only the iPhone slice. Cerbero owns codec sources, patches and packaging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERBERO="$ROOT/.build/runtime-sources/cerbero"
CONFIG="$ROOT/.build/cerbero-ci.cbc"
JOBS="${IRIDIUM_BUILD_JOBS:-2}"
[ "$#" -eq 0 ] || [ "$*" = --preflight ] || { echo "Usage: $0 [--preflight]" >&2; exit 2; }
mkdir -p "$ROOT/.build"
case "$JOBS" in ''|*[!0-9]*|0) echo 'Invalid compiler job count' >&2; exit 2;; esac
python3 - "$CONFIG" "$ROOT/.build/cerbero-home" "$JOBS" "$ROOT/iridium/apps/ios/stikjit.yml" <<'PY'
from pathlib import Path
import platform
import re
import sys
targets = set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET: "([0-9.]+)"', Path(sys.argv[4]).read_text()))
if len(targets) != 1:
    raise SystemExit('Expected one explicit app iOS deployment target')
Path(sys.argv[1]).write_text('home_dir = ' + repr(sys.argv[2]) + '\nnum_of_cpus = ' + sys.argv[3] + '\nios_min_version = ' + repr(targets.pop()) + '\n')
# Cerbero loads this for its separate host-tools configuration too. These
# tools run only on the build host. iPhone libraries use the app target above.
host_config = Path.home() / '.cerbero' / 'cerbero.cbc'
host_config.parent.mkdir(exist_ok=True)
expected = 'min_osx_sdk_version = ' + repr(platform.mac_ver()[0]) + '\n'
if host_config.exists():
    if host_config.read_text() != expected:
        raise SystemExit('Existing Cerbero host configuration differs; refusing to overwrite it')
else:
    with host_config.open('x') as config:
        config.write(expected)
PY
# Source packaging uses setuptools, which Homebrew Python does not include.
PACKAGING_PYTHON="$ROOT/.build/media-packaging/bin/python3"
python3 -m venv "$ROOT/.build/media-packaging"
"$PACKAGING_PYTHON" -m pip install --disable-pip-version-check 'setuptools==80.9.0'
python3 "$ROOT/ci/check-media-toolchain.py" "$CERBERO" "$CONFIG"
git -C "$ROOT" apply --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-gperf-cxx14.patch"
git -C "$ROOT" apply --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-assets-library.patch"
if git -C "$ROOT" apply --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch" 2>/dev/null; then
    git -C "$ROOT" apply --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch"
else
    git -C "$ROOT" apply --reverse --check --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-source-manifest.patch"
fi
"$PACKAGING_PYTHON" "$ROOT/ci/check-media-source-package.py" "$CERBERO"
[ "${1:-}" != --preflight ] || exit 0
cd "$CERBERO"
git -C "$ROOT" apply --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-gperf-cxx14.patch"
git -C "$ROOT" apply --directory=.build/runtime-sources/cerbero "$ROOT/ci/patches/cerbero-assets-library.patch"
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    bootstrap --assume-yes --jobs "$JOBS"
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    package gstreamer-1.0 --artifact=xcframework --jobs "$JOBS"
# The package artifact is a framework input, not the final XCFramework.
python3 cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    xcframework gstreamer-1.0 --source gstreamer-1.0-1.28.6-ios-arm64.xcframework.tar.xz
"$PACKAGING_PYTHON" cerbero-uninstalled -c config/cross-ios-arm64.cbc -c "$CONFIG" \
    bundle-source gstreamer-1.0 --offline
mkdir -p "$ROOT/.build/corresponding-source"
cp dist/cerbero-1.28.6.tar.xz "$ROOT/.build/corresponding-source/"
python3 - "$CERBERO" "$ROOT/iridium/apps/ios/.build/media-sdk" <<'PY'
from pathlib import Path
import sys, tarfile
source, output = map(Path, sys.argv[1:])
archives = list(source.glob('gstreamer-1.28.6-xcframework.tar.xz'))
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
