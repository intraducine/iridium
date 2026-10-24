# Wine userland bridge

Retained prefix/userland producer for the [embedded runtime SDK](../../../iridium-runtime-sdk/README.md).
The current app uses native Madeira Wine separately.

## Build and package

From this directory, with Docker running:

```sh
./build_install_root.sh --platform linux-x86_64 \
  --build-root /absolute/path/to/wine-build \
  --install-root /absolute/path/to/wine-install
./stage_userland.sh --source-root /absolute/path/to/wine-install \
  --output-root /absolute/path/to/wine-staged
./package_userland.sh --source-root /absolute/path/to/wine-staged \
  --prefix-seed /absolute/path/to/wine-staged/prefix-seed \
  --output /absolute/path/to/wine-userland.tar.zst
make test
```

`linux-x86_64` is the embedded-FEX guest producer. `host`, `device`, and
`simulator` producers require PE cross tools (MinGW, LLVM, LLD) and produce Apple
host payloads; those are not valid embedded-FEX guest archives.

The canonical staging/packaging scripts reject incomplete or hand-prepared roots.
The output needs wineserver, a launcher, Wine libraries/data, a compatible
x86_64 ELF loader, Linux dependencies, and `prefix-seed/{system,user,userdef}.reg`.
A preloader requires its Unix Wine companion and any PT_INTERP interpreter at
the original guest path. Host Mach-O launchers alone are rejected.

`generate_prefix_seed.sh --output /path/to/seed` creates the source-owned seed.
Preparation creates `dosdevices/c:` and `z:` and uses win64 direct-launch settings
with `IRIDIUM_NO_DESKTOP=1` and `IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1`.
Blocked desktop/launcher entries are pruned. SDK bundle assembly and device
validation remain separate from these staging tests.
