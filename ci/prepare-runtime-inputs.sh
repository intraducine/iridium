#!/bin/bash
# Hybrid regression build: keep the current app checkout, but compile the
# Madeira/FEX/Wine native runtime from the last known-working native revision.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MADEIRA="$ROOT/testrepos/Madeira"
NATIVE_REV="65b596cb74635a2f7ff6b39ca6da208466fe78c1"

cd "$ROOT"
echo "Hybrid native regression build: app=$(git rev-parse HEAD) native=$NATIVE_REV"

# Actions checks out only the current branch tip. Fetch the old native producer
# explicitly, then restore ONLY native runtime sources and their compiler recipes.
# iridium/apps/ios stays at the current branch so LiveContainer, JIT integration,
# controller/UI code, and app packaging remain from e62b22f5.
git fetch --no-tags --depth=1 origin "$NATIVE_REV"
git checkout "$NATIVE_REV" -- \
    testrepos/Madeira \
    iridium-fex-ios \
    iridium-wine-ios \
    ci/prepare-native-runtime.sh \
    ci/compile-wine.sh \
    ci/compile-windows-modules.sh \
    ci/prepare-windows-runtime.sh

# Record the two sides of the hybrid in the build log/workspace.
mkdir -p "$ROOT/.build"
printf 'app_revision=%s\nnative_revision=%s\n' \
    "$(git rev-parse HEAD)" "$NATIVE_REV" > "$ROOT/.build/hybrid-native-revisions.txt"
cat "$ROOT/.build/hybrid-native-revisions.txt"

# This is intentionally the 65b596 input-preparation behavior. In particular,
# do NOT apply the later rpmalloc/FEX correction patches from current e62.
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk iphoneos metal --version
python3 "$ROOT/ci/fetch-runtime-inputs.py"

# Use exact gitlink commits from the restored native trees. Do not fetch binary
# test corpora or unrelated modules.
modules=()
for fork in iridium-fex-ios testrepos/Madeira/FEX; do
    for module in fmt range-v3 rpmalloc unordered_dense vixl xxhash; do
        modules+=("$fork/External/$module")
    done
    modules+=("$fork/Source/Common/cpp-optparse")
done
modules+=(testrepos/Madeira/research/dxmt/include/native/directx)
git submodule update --init --depth 1 -- "${modules[@]}"

# Guard the experiment: the current allocator-correction path must not have run.
if git -C "$MADEIRA/FEX/External/rpmalloc" diff --quiet; then
    echo "Hybrid native inputs ready at $NATIVE_REV"
else
    echo "Unexpected dirty rpmalloc tree in hybrid native build" >&2
    git -C "$MADEIRA/FEX/External/rpmalloc" diff --stat >&2 || true
    exit 1
fi
