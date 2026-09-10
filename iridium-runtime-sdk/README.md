# Iridium Runtime SDK

`iridium-runtime-sdk` is the separate build and packaging workspace for the internal Iridium Windows runtime. It exists to produce versioned runtime bundles that the main Iridium app repo can ingest without changing the app-side manifest or provisioning contract.

Current scope:
- Internal-only and sideload-only
- x64 Windows executables only
- Wine-derived userland
- FEX-derived translator
- OpenGL-only first milestone
- No desktop shell exposure
- iOS uses the embedded host-core library path; `runtime-host.bin` is the CLI and macOS harness entrypoint

Bundle output layout:
- `Runtime/runtime-host.bin`
- `Translator/x64-jit.bin`
- `Userland/wine-userland.tar.zst`
- `Graphics/vkd3d-stack.json`
- `Graphics/ios-presentation-backend.json`
- `Metadata/direct-launch.json`
- `manifest.json`

The native host in this repo implements the Iridium backend file contract:
- Reads a launch package written by the app/runtime layer
- Writes session updates, terminal result, telemetry, and host logs
- Writes `host-capabilities.json` into the managed root derived from the launch package's `runtimeBundleRootPath`

Phase 2C hardening rules in this repo:
- The bundled embedded path is the product path.
- External Wine execution is development-only and must be enabled explicitly with `IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE=1`.
- Telemetry is honest: the host writes it only when concrete metrics are provided, otherwise it leaves telemetry absent.
- The translator artifact is expected to be the embedded FEX bridge payload consumed by the host, not a generic standalone translator binary.
- Embedded direct launch also requires the staged Wine userland to expose an x86_64 ELF Unix-side Wine loader such as `lib/wine/x86_64-unix/wine` or `lib64/wine/x86_64-unix/wine`; bundles that only contain host Mach-O launchers like `bin/wine` or `bin/wine64` are now rejected during validation/bootstrap.
- `Package.swift` now validates the canonical embedded-FEX manifests at `../iridium-fex-ios/build-iridium-ios-host`, `../iridium-fex-ios/build-iridium-ios-iphoneos`, and `../iridium-fex-ios/build-iridium-ios-iphonesimulator` during package resolution.
- Local Swift package manifests under Xcode do not receive destination-aware environment, so per-SDK iOS link selection lives in consumer build settings; `build-iridium-ios-current` is compatibility-only and is not the product link path.

## Bootstrap Source Forks

```bash
cd $IRIDIUM_SDK_ROOT
./scripts/bootstrap_source_forks.sh
```

This creates or updates the sibling source-owned workspaces:
- `$IRIDIUM_FEX_ROOT`
- `$IRIDIUM_WINE_ROOT`

The script uses the vendored upstream mirrors when present and falls back to GitHub clones when needed.

## Refresh Vendored Upstream Mirrors

```bash
cd $IRIDIUM_SDK_ROOT
./scripts/fetch_upstreams.sh
```

This refreshes `upstream/FEX` and `upstream/wine` from upstream remotes for reference and fork bootstrapping.

## Prepare Canonical Apple Translator Artifacts

Before building this package through SwiftPM or using it from the main Iridium app repo, refresh the canonical embedded FEX artifacts:

```bash
cd $IRIDIUM_FEX_ROOT
./iridium/ios/build_embedded_translator.sh --platform host
./iridium/ios/build_embedded_translator.sh --platform device
./iridium/ios/build_embedded_translator.sh --platform simulator
```

Those default-root invocations refresh the manifests and SDK alias roots that the package graph and Xcode consumers expect: `build-iridium-ios-host`, `build-iridium-ios-iphoneos`, and `build-iridium-ios-iphonesimulator`.

## Build the Native Host

```bash
cd $IRIDIUM_SDK_ROOT
cmake -S . -B build
cmake --build build
```

This produces:
- `build/runtime-host.bin`
- `iridium-runtime-host-core`, the reusable host library that an iOS embedding path can link in-process

You can also build the same host core through SwiftPM so the main Iridium package can link it directly on Apple platforms:

```bash
cd $IRIDIUM_SDK_ROOT
swift build
```

This produces:
- the `IridiumRuntimeHostSDK` package product for in-process Apple embedding
- the `runtime-host.bin` executable product for CLI and harness validation

## Package a Runtime Bundle

Provide real prebuilts for the translator and Wine userland, then run:

```bash
cd $IRIDIUM_SDK_ROOT
./scripts/build_runtime_bundle.sh \
  --bundle-version <bundle-version> \
  --smoke-check \
  --translator /abs/path/to/x64-jit.bin \
  --userland /abs/path/to/wine-userland.tar.zst \
  --fex-fork-root $IRIDIUM_FEX_ROOT \
  --wine-fork-root $IRIDIUM_WINE_ROOT \
  --output-root /abs/path/to/output/iridium-runtime-base
```

If you already built `runtime-host.bin` yourself, call the packager directly:

```bash
python3 ./scripts/package_runtime_bundle.py \
  --bundle-id iridium-runtime-base \
  --bundle-name "Iridium Runtime Base" \
  --bundle-version <bundle-version> \
  --runtime-host ./build/runtime-host.bin \
  --translator /abs/path/to/x64-jit.bin \
  --userland /abs/path/to/wine-userland.tar.zst \
  --fex-fork-root $IRIDIUM_FEX_ROOT \
  --wine-fork-root $IRIDIUM_WINE_ROOT \
  --graphics-config ./samples/runtime-bundle-template/Graphics/vkd3d-stack.json \
  --direct-launch-profile ./samples/runtime-bundle-template/Metadata/direct-launch.json \
  --output-root /abs/path/to/output/iridium-runtime-base \
  --smoke-check
```

Import the resulting bundle into the main app repo with:

```bash
cd $IRIDIUM_APP_ROOT
./scripts/import-runtime-bundle.sh /abs/path/to/output/iridium-runtime-base
```

The host, embedded FEX bridge, and bundle pipeline are implemented and exercised on macOS plus iOS device/simulator builds. A playable physical-device session still requires an attached debugger/JIT provider and continued Wine-on-iOS syscall, signal, TLS, thread, and per-title graphics validation. This repo provides:
- the native host binary
- a reusable host core library for eventual iOS embedding
- source-owned fork bootstrap for Wine and FEX
- the bundle-packaging pipeline
- the exact artifact/manifest contract Iridium already validates

## Build Directly From Source Forks

If the sibling `iridium-fex-ios` and `iridium-wine-ios` workspaces exist, the SDK can assemble a bundle from those fork-owned outputs:

```bash
cd $IRIDIUM_SDK_ROOT
./scripts/doctor.sh
./scripts/build_runtime_bundle.sh \
  --bundle-version <bundle-version> \
  --smoke-check \
  --build-from-forks \
  --fex-platform device \
  --wine-platform linux-x86_64 \
  --fex-fork-root $IRIDIUM_FEX_ROOT \
  --wine-fork-root $IRIDIUM_WINE_ROOT \
  --output-root /abs/path/to/output/iridium-runtime-base
```

Implementation details:
- the SDK builds `runtime-host.bin` with `cmake` when available and falls back to `swift build` otherwise
- the FEX fork builds the Iridium-only translator bridge through `IRIDIUM_IOS_EMBEDDED=ON`, using `--platform host` for local host validation and `--platform device` for runtime bundle assembly; default-root invocations also refresh the canonical SDK aliases `build-iridium-ios-host`, `build-iridium-ios-iphoneos`, and `build-iridium-ios-iphonesimulator`
- the Wine fork now builds the canonical embedded-FEX userland through `iridium/ios/build_install_root.sh --platform linux-x86_64`, which runs inside Docker on macOS, stages the install root through `iridium/ios/stage_userland.sh`, generates a source-owned `prefix-seed` through `iridium/ios/generate_prefix_seed.sh`, and packages the resulting `wine-userland.tar.zst` through `iridium/ios/package_userland.sh`
- `--wine-prefix-seed` is now optional and only overrides where the SDK asks the Wine fork to generate the canonical prefix-seed payload
- `--wine-userland-source-root` is still accepted for compatibility with older local commands but is no longer required by the source-fork build path
- `--fex-platform` defaults to `host` and writes the canonical translator artifact into `build/fex-ios-embedded-<platform>`
- `--wine-platform` defaults to `linux-x86_64` and writes the canonical userland artifact into `build/wine-userland-<platform>`
- `--smoke-check` runs a deterministic local validation pass over the assembled bundle and host contract before import into the app repo
