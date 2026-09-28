#!/bin/bash
# Stage the verified iOS converter and its required notices.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/deps.sh"
DEST_DIR="$REPO_ROOT/app/Madeira/d3d12"
cp "$MSC_LIB_IOS" "$DEST_DIR/libmetalirconverter.dylib"
bash "$REPO_ROOT/build/stage-licenses.sh"
echo "staged verified iOS Metal Shader Converter -> $DEST_DIR"
