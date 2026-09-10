# Iridium Wine iOS Bridge

This directory holds the Iridium-owned iOS bridge surface for the Wine fork.

Current scope:
- own iOS-specific prefix and userland helpers in the Wine source fork
- keep direct-launch-only policy enforcement close to the future Wine port
- give the runtime host a narrow, source-owned API for prefix preparation
- require a seeded, direct-launch-safe userland payload for the Iridium path
- expose an Iridium-only bootstrap skip gate for seeded prefixes

This is not the full Wine iOS port yet. It is the fork-owned bridge layer that
the runtime SDK and embedded host will eventually call.

Current guarantees for the Iridium path:
- the packaged userland must include `bin/wineserver`, a Wine launcher entrypoint, an embedded-FEX-compatible x86_64 ELF Unix-side loader without PT_INTERP, Wine libs, `share/wine`, and `prefix-seed/{system,user,userdef}.reg`; when the loader is `wine-preloader`, the sibling Unix `wine`/`wine64` companion, any PT_INTERP interpreter it names, and Linux shared-library dependency directories staged from `ldd` must also be present
- prefix preparation creates the `dosdevices/c:` and `dosdevices/z:` links
- direct-launch bootstrap hydrates a seeded prefix and exports:
  - `IRIDIUM_NO_DESKTOP=1`
  - `IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1`
  - `WINEPREFIX`
  - `WINEARCH=win64`
  - `WINEDEBUG=-all`
  - `WINESERVER`

Current limitation:
- the `--platform device` and `--platform simulator` install-root producer currently builds host-side Wine Unix launchers for Apple arm64 (`bin/wine`, `lib/wine/aarch64-unix/wine`); that output is sufficient for prefix/bootstrap staging, but it is not an embedded-FEX guest payload
- the canonical embedded-FEX userland producer is now `--platform linux-x86_64`, which builds a Linux/x86_64 Wine install root inside Docker so the staged payload contains a PT_INTERP-free x86_64 ELF Unix-side Wine loader, preferably `lib/wine/x86_64-unix/wine-preloader`
- `stage_userland.sh` and `package_userland.sh` now reject staged roots that only expose host Mach-O launchers, x86_64 ELF loaders that still declare PT_INTERP, or preloader roots whose sibling Unix Wine companion is missing its PT_INTERP interpreter

Host prerequisite for the Apple-hosted producers (`host`, `device`, `simulator`):
- install a PE-capable cross toolchain that exposes `x86_64-w64-mingw32-gcc` or `x86_64-w64-mingw32-clang`
- on Apple Silicon hosts, Wine also needs an `aarch64-windows` PE path via Homebrew LLVM + LLD so the host-side PE probe can pass
- on this macOS setup the supported path is:

```bash
brew install mingw-w64 llvm lld
```

Host prerequisite for the embedded-FEX guest producer:
- Docker must be installed and the daemon must be running

Canonical real install-root producer:
```bash
cd ~/Developer/Repositories/iridium-wine-ios/iridium/ios
./build_install_root.sh \
  --platform linux-x86_64 \
  --build-root /abs/path/to/wine-build \
  --install-root /abs/path/to/wine-install-root
```

Supported `--platform` values:
- `device`: Cross-compile for iOS arm64
- `simulator`: Cross-compile for iOS Simulator
- `host`: Build for macOS host (for development/testing)
- `linux-x86_64`: Build the embedded-FEX guest Wine payload inside Docker

This is the only supported Phase 2C producer for a real Wine install root. It configures Wine out-of-tree, builds the win64 tree with PE cross-compilation enabled, runs `make install`, stages Linux runtime dependencies reported by `ldd`, and verifies the resulting install root exposes `bin/wineserver`, a Wine launcher, Wine libs, and `share/wine`. For `linux-x86_64`, the script also verifies that the install root exposes an embedded-FEX-compatible x86_64 ELF Wine loader. For `device` and `simulator`, the install root is still a host-side Apple arm64 Wine payload and is therefore not valid input for the canonical stage/package flow.

Canonical fork-owned staging flow:
```bash
cd ~/Developer/Repositories/iridium-wine-ios/iridium/ios
./stage_userland.sh \
  --source-root /abs/path/to/wine-install-root \
  --output-root /abs/path/to/staged-wine-userland
```

This is the only supported way to prepare the staged userland root that `package_userland.sh` accepts.
The staged root must contain:
- `bin/wineserver`
- `bin/wine64` or `bin/wine`
- an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP, preferably `lib/wine/x86_64-unix/wine-preloader` or `lib64/wine/x86_64-unix/wine-preloader`, and otherwise `lib/wine/x86_64-unix/wine` or `lib64/wine/x86_64-unix/wine`
- for `wine-preloader`, a sibling Unix `wine`/`wine64` companion and any PT_INTERP interpreter that companion names, copied at the same guest path such as `lib64/ld-linux-x86-64.so.2`
- Linux runtime dependency directories produced by `stage_linux_runtime_deps.sh`, including paths such as `lib/x86_64-linux-gnu` and `usr/lib/x86_64-linux-gnu` when `ldd` reports them
- `lib/wine` or `lib64/wine`
- `share/wine`
- `prefix-seed/system.reg`
- `prefix-seed/user.reg`
- `prefix-seed/userdef.reg`

Canonical fork-owned prefix-seed flow:
```bash
cd ~/Developer/Repositories/iridium-wine-ios/iridium/ios
./generate_prefix_seed.sh --output /abs/path/to/prefix-seed
```

The generated seed payload is versioned in this fork under `iridium/ios/prefix-seed-template` and is win64-only, direct-launch-only, and suitable for `IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1`.

Canonical packaging flow:
```bash
cd ~/Developer/Repositories/iridium-wine-ios/iridium/ios
./package_userland.sh \
  --source-root /abs/path/to/staged-wine-userland \
  --output /abs/path/to/wine-userland.tar.zst \
  --prefix-seed /abs/path/to/staged-wine-userland/prefix-seed
```

Packaging contract:
- `package_userland.sh` is the only supported producer for `wine-userland.tar.zst`
- the script rejects incomplete staged roots, missing seed files, staged roots without an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP, preloader roots missing the sibling companion interpreter, and non-canonical hand-prepared roots
- blocked shell and launcher executables are pruned from packaged `share/wine`
- the archive shape is the downstream SDK contract consumed by `build_runtime_bundle.sh --build-from-forks`

Repo ownership boundary:
- this repo owns staging, prefix-seed production, bridge validation, direct-launch bootstrap, and `wine-userland.tar.zst` production
- SDK bundle assembly, import into the main app repo, and physical-device proof remain outside this repo

Local verification:
```bash
cd iridium/ios
make test
```

End-to-end Phase 2C fork flow:
```bash
cd ~/Developer/Repositories/iridium-wine-ios/iridium/ios
INSTALL_ROOT=$(./build_install_root.sh \
  --platform linux-x86_64 \
  --build-root /abs/path/to/wine-build \
  --install-root /abs/path/to/wine-install-root)
./stage_userland.sh \
  --source-root "$INSTALL_ROOT" \
  --output-root /abs/path/to/staged-wine-userland
./package_userland.sh \
  --source-root /abs/path/to/staged-wine-userland \
  --output /abs/path/to/wine-userland.tar.zst \
  --prefix-seed /abs/path/to/staged-wine-userland/prefix-seed
```
