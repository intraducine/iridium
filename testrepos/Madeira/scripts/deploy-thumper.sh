#!/bin/bash
# Push Thumper game directory to the iPhone's Madeira.app Documents container.
# Game ends up at C:\Program Files\Thumper\ from Wine's perspective
# (Documents/wine/drive_c/Program Files/Thumper/ on the device filesystem).
#
# This is the dev-iteration path. For distribution, the game would be bundled
# in the .app and extracted on first launch via PrefixExtractor (TODO).
set -eu

DEVICE_ID="DEVICE_UDID"
BUNDLE_ID="com.madeira.emulator"
SRC_DIR="/Users/willfaust/Documents/ios-pc-game-claude/research/Games/Thumper"
DST_PATH='Documents/wine/drive_c/Program Files/Thumper'

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source directory not found: $SRC_DIR"
    exit 1
fi

echo "==> Source: $SRC_DIR ($(du -sh "$SRC_DIR" | awk '{print $1}'))"
echo "==> Destination: <app container>/$DST_PATH"
echo ""

# devicectl copy doesn't auto-create parent dirs; create them by pushing
# a placeholder first if needed. Instead, the simplest reliable approach is
# to push the entire Thumper folder under "Program Files/" — the parent
# "wine/drive_c/Program Files/" should already exist after first Madeira
# launch (the prefix extractor creates drive_c/ and standard subdirs).
#
# devicectl behaves like cp -R when the source is a directory.

echo "==> Pushing game directory (this can take 30-60s for ~870MB)..."
xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --source "$SRC_DIR" \
    --destination "$DST_PATH" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    2>&1 | tail -20

echo ""
echo "==> Done. Tap 'Run Thumper (D3D11 / win10)' in the Madeira app to launch."
