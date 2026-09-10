#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
PARENT_ROOT=${ROOT:h}
WINE_SOURCE="$ROOT/upstream/wine"
FEX_SOURCE="$ROOT/upstream/FEX"
WINE_DEST="$PARENT_ROOT/iridium-wine-ios"
FEX_DEST="$PARENT_ROOT/iridium-fex-ios"
PORT_BRANCH="codex/ios-port-base"

function clone_or_refresh_fork() {
  local source_path="$1"
  local fallback_url="$2"
  local destination="$3"

  if [[ -d "$destination/.git" ]]; then
    git -C "$destination" fetch --all --tags --prune
  elif [[ -d "$source_path/.git" ]]; then
    git clone --shared "$source_path" "$destination"
  else
    git clone --filter=blob:none "$fallback_url" "$destination"
  fi

  if ! git -C "$destination" rev-parse --verify "$PORT_BRANCH" >/dev/null 2>&1; then
    git -C "$destination" checkout -b "$PORT_BRANCH"
  else
    git -C "$destination" checkout "$PORT_BRANCH"
  fi

  if [[ -f "$destination/.gitmodules" ]]; then
    git -C "$destination" submodule update --init --recursive
  fi
}

clone_or_refresh_fork "$WINE_SOURCE" "https://github.com/wine-mirror/wine.git" "$WINE_DEST"
clone_or_refresh_fork "$FEX_SOURCE" "https://github.com/FEX-Emu/FEX.git" "$FEX_DEST"

echo "Prepared source-owned fork workspaces:"
echo "  $WINE_DEST"
echo "  $FEX_DEST"
