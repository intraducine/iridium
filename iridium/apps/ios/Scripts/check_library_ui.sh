#!/bin/sh
set -eu
# Standalone native preview and persistence checks; never launches a game or touches a phone.
repo=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
build_root=${IRIDIUM_LIBRARY_CHECK_ROOT:-/tmp/iridium-library-check}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
mkdir -p "$build_root"
python3 - "$repo" "$build_root" <<'PY'
import pathlib, sys
repo, out = map(pathlib.Path, sys.argv[1:])
text = (repo / 'apps/ios/LibrarySupportTests/project.yml.template').read_text()
(out / 'project.yml').write_text(text.replace('__REPOSITORY__', str(repo)))
PY
xcodegen generate --spec "$build_root/project.yml"
xcodebuild -quiet -project "$build_root/LibraryPreview.xcodeproj" -scheme LibraryPreview \
  -destination "platform=iOS Simulator,name=${IRIDIUM_LIBRARY_SIMULATOR:-iPhone 17 Pro}" \
  -derivedDataPath "$build_root/build" CODE_SIGNING_ALLOWED=NO test
