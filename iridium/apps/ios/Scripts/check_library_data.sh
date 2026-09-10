#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
check_root=$(mktemp -d /tmp/iridium-library-data.XXXXXX)
python3 - "$repo" "$check_root" <<'PY'
import sys, shutil
from pathlib import Path
repo, root = map(Path, sys.argv[1:])
for folder in ['Sources/IridiumCore', 'Tests/IridiumCoreTests']:
    shutil.copytree(repo/'packages/core'/folder, root/folder)
(root/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LibraryDataCheck", platforms: [.macOS(.v14)], targets: [.target(name: "IridiumCore"), .testTarget(name: "IridiumCoreTests", dependencies: ["IridiumCore"])])
''')
PY
swift test --package-path "$check_root" --filter testRemoveLibraryEntryPreservesFilesAndPrefix
