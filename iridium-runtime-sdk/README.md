# Iridium Runtime SDK

Retained SDK for the earlier embedded FEX/Wine backend. The current app uses
[native Madeira](../docs/runtime-integration.md). This SDK owns the in-process
host library, CLI harness, and versioned runtime-bundle packaging.

The retained backend supports direct x64/OpenGL launch with external JIT. Its
partial Darwin syscall bridge is not a complete Wine-on-iOS implementation.

## Build

Prepare FEX artifacts from `../iridium-fex-ios`:

```sh
./iridium/ios/build_embedded_translator.sh --platform host
./iridium/ios/build_embedded_translator.sh --platform device
./iridium/ios/build_embedded_translator.sh --platform simulator
```

Then run from this directory:

```sh
cmake -S . -B build
cmake --build build
```

`swift build` also exposes `IridiumRuntimeHostSDK` and `runtime-host.bin`.
SwiftPM checks manifests in FEX's `build-iridium-ios-host`, `-iphoneos`, and
`-iphonesimulator` aliases. Consumers select the SDK-specific path, not `-current`.

## Bundle

With Docker running for the Linux Wine build:

```sh
./scripts/build_runtime_bundle.sh \
  --bundle-version 0.1.0 --smoke-check --build-from-forks \
  --fex-platform device --wine-platform linux-x86_64 \
  --fex-fork-root ../iridium-fex-ios --wine-fork-root ../iridium-wine-ios \
  --output-root /absolute/path/to/iridium-runtime-base
```

Choose the intended bundle version. For existing artifacts, replace
`--build-from-forks` and platform options with `--translator /path/to/x64-jit.bin`
and `--userland /path/to/wine-userland.tar.zst`.

The [bundle template](samples/runtime-bundle-template/README.md) defines layout;
[host-contract.md](docs/host-contract.md) defines launch/results. Wine userland
must contain a compatible ELF loader, interpreter/dependencies, and prefix seed.
Host Mach-O launchers alone are invalid.

`bootstrap_source_forks.sh` creates reference fork workspaces; `fetch_upstreams.sh`
refreshes upstream mirrors. Existing monorepo forks can be passed directly.
Run `scripts/doctor.sh` for setup checks. Host/smoke tests do not prove gameplay.
