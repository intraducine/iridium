#!/bin/bash
# Restore pinned sources and tools independently of compiler output reuse.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MADEIRA="$ROOT/testrepos/Madeira"
# Resolve the separately installed Metal compiler before LLVM/FEX compilation.
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk iphoneos metal --version
python3 "$ROOT/ci/fetch-runtime-inputs.py"

# Use exact gitlink commits. Do not fetch binary test corpora or unrelated modules.
cd "$ROOT"
modules=()
for fork in iridium-fex-ios testrepos/Madeira/FEX; do
    for module in fmt range-v3 rpmalloc unordered_dense vixl xxhash; do
        modules+=("$fork/External/$module")
    done
    modules+=("$fork/Source/Common/cpp-optparse")
done
modules+=(testrepos/Madeira/research/dxmt/include/native/directx)
git submodule update --init --depth 1 -- "${modules[@]}"
