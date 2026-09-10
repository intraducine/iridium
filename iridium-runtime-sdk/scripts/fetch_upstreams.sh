#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
UPSTREAM_ROOT="$ROOT/upstream"
mkdir -p "$UPSTREAM_ROOT"

function clone_or_update() {
  local repo_url="$1"
  local destination="$2"

  if [[ -d "$destination/.git" ]]; then
    git -C "$destination" fetch --depth 1 origin
    git -C "$destination" reset --hard origin/HEAD
  else
    git clone --depth 1 --filter=blob:none "$repo_url" "$destination"
  fi
}

clone_or_update "https://github.com/FEX-Emu/FEX.git" "$UPSTREAM_ROOT/FEX"
clone_or_update "https://github.com/wine-mirror/wine.git" "$UPSTREAM_ROOT/wine"

echo "Upstream source trees are available in $UPSTREAM_ROOT"

