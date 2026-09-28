#!/bin/bash
# Resolve the pinned converter from an official local installer or release asset.
# Libraries retain Apple's agreement; headers retain Apache-2.0. No Apple login
# or installer is needed on hosted runners. Verify cached contents on each use.
set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MSC_PKG="${MADEIRA_MSC_PKG:-$REPO_ROOT/research/GPTK/Metal Shader Converter 4.0 beta 2.pkg}"
MSC_PKG_SHA256="0e7b6c83617a0b67905614579e82031d177ed49cfaacccb0aaef6ddadf19107c"
MSC_ARCHIVE_SHA256="f61c5bf4eadb993430642bb32c5642b1ddf2479a97b22ac307564967a4ff69d4"
MSC_ARCHIVE_ROOT="metal-shader-converter-4.0-beta2"

if [[ -f "$MSC_PKG" || -n "${MADEIRA_MSC_PKG:-}" ]]; then
    [[ -f "$MSC_PKG" ]] || { echo "deps: requested installer is missing" >&2; exit 1; }
    [[ "$(shasum -a 256 "$MSC_PKG" | cut -d' ' -f1)" == "$MSC_PKG_SHA256" ]] || {
        echo "deps: converter package hash mismatch" >&2; exit 1;
    }
    MSC_ROOT="$(mktemp -d /private/tmp/madeira-msc-XXXXXX)/expanded"
    pkgutil --expand-full "$MSC_PKG" "$MSC_ROOT" >/dev/null
else
    python3 "$REPO_ROOT/../../ci/fetch-runtime-inputs.py" --only metal-shader-converter
    MSC_ARCHIVE="$REPO_ROOT/.build/metal-shader-converter.tar.gz"
    [[ "$(shasum -a 256 "$MSC_ARCHIVE" | cut -d' ' -f1)" == "$MSC_ARCHIVE_SHA256" ]] || {
        echo "deps: converter release hash mismatch" >&2; exit 1;
    }
    MSC_ROOT="$REPO_ROOT/.build/msc-$MSC_ARCHIVE_SHA256/$MSC_ARCHIVE_ROOT"
    if [[ ! -d "$MSC_ROOT" ]]; then
        mkdir -p "$(dirname "$MSC_ROOT")"
        tar -xzf "$MSC_ARCHIVE" -C "$(dirname "$MSC_ROOT")"
    fi
    # Read the manifest from the verified archive, not the mutable extraction.
    (cd "$MSC_ROOT" && tar -xOf "$MSC_ARCHIVE" "$MSC_ARCHIVE_ROOT/SHA256SUMS" |
        shasum -a 256 -c - >/dev/null) || {
        echo "deps: converter extraction is damaged; remove $MSC_ROOT and retry" >&2; exit 1;
    }
fi

MSC_PAYLOAD="$MSC_ROOT/MetalShaderConverter.pkg/Payload"
MSC_INCLUDE="$MSC_PAYLOAD/usr/local/include"
MSC_LIB_MACOS="$MSC_PAYLOAD/usr/local/lib/libmetalirconverter.dylib"
MSC_LIB_IOS="$MSC_PAYLOAD/usr/local/lib_iOS/libmetalirconverter.dylib"

for f in "$MSC_INCLUDE/metal_irconverter/metal_irconverter.h" \
         "$MSC_INCLUDE/metal_irconverter_runtime/metal_irconverter_runtime.h" \
         "$MSC_LIB_MACOS" "$MSC_LIB_IOS"; do
    [[ -e "$f" ]] || { echo "deps: extraction incomplete, missing $f" >&2; exit 1; }
done

[[ "$(shasum -a 256 "$MSC_LIB_IOS" | cut -d' ' -f1)" == \
   "073f903be98e973ff38f4d79f2c48d61ef938754a77b1caedda79c9f05a068c2" ]] || {
    echo "deps: extracted iOS converter hash mismatch" >&2; exit 1;
}

export MSC_ROOT MSC_PAYLOAD MSC_INCLUDE MSC_LIB_MACOS MSC_LIB_IOS
