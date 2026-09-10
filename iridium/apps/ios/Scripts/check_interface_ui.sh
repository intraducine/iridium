#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
build_root=${IRIDIUM_INTERFACE_CHECK_ROOT:-/tmp/iridium-interface-check}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
mkdir -p "$build_root"
python3 - "$repo" "$build_root" <<'PY'
from pathlib import Path
import sys
repo, out = map(Path, sys.argv[1:])
(out / 'project.yml').write_text((repo / 'apps/ios/InterfaceTests/project.yml.template').read_text().replace('__REPOSITORY__', str(repo)))
PY
xcodegen generate --spec "$build_root/project.yml"
xcodebuild -project "$build_root/InterfacePreview.xcodeproj" -scheme InterfacePreview \
  -destination "platform=iOS Simulator,name=${IRIDIUM_LIBRARY_SIMULATOR:-iPhone 17 Pro}" \
  -derivedDataPath "$build_root/build" CODE_SIGNING_ALLOWED=NO test
