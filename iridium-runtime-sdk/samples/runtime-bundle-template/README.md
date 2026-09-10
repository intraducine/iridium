# Runtime Bundle Template

This template documents the exact directory structure the runtime SDK must emit. Real translator and Wine payloads are not checked into this repo.

Expected output:
- `Runtime/runtime-host.bin`
- `Translator/x64-jit.bin`
- `Userland/wine-userland.tar.zst`
- `Graphics/vkd3d-stack.json`
- `Metadata/direct-launch.json`
- `manifest.json`

Use `scripts/build_runtime_bundle.sh` or `scripts/package_runtime_bundle.py` to generate the final bundle from real translator and Wine payloads plus the source-fork revisions that produced them.
