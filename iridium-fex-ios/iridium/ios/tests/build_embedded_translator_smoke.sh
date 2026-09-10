#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: build_embedded_translator_smoke.sh <build-root> <platform>" >&2
  exit 64
fi

build_root="$1"
platform="$2"
manifest="$build_root/iridium-ios-embedded-artifact.txt"
archive="$build_root/artifacts/libiridium-fex-ios-embedded.a"

if [ ! -f "$manifest" ]; then
  echo "missing embedded translator manifest: $manifest" >&2
  exit 66
fi

if [ ! -f "$archive" ]; then
  echo "missing embedded translator archive: $archive" >&2
  exit 66
fi

if ! grep -qx "MODE=embedded" "$manifest"; then
  echo "embedded translator manifest is missing MODE=embedded: $manifest" >&2
  exit 66
fi

if ! grep -qx "PLATFORM=$platform" "$manifest"; then
  echo "embedded translator manifest does not declare PLATFORM=$platform: $manifest" >&2
  exit 66
fi

if ! grep -qx "TARGET=iridium-fex-ios-embedded" "$manifest"; then
  echo "embedded translator manifest is missing the expected target: $manifest" >&2
  exit 66
fi

echo "Embedded translator build-root smoke passed for $platform."
