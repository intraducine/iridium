# Setup

The Iridium workspace is now multi-repo. This repo owns the app shell and Swift packages, while the native runtime host and engine-port work live in sibling repos beside it.

## Prerequisites

- macOS with current Xcode installed.
- Accepted local Xcode and Apple SDK license via `sudo xcodebuild -license accept`.
- Apple platform command line tools enabled.
- Git.
- `xcodegen` installed locally.
- `python3`, `tar`, and `zstd` available on PATH.
- `zsh` for the Wine fork build/stage/package helpers.
- CMake for native host and FEX bridge builds. SwiftPM is still used for app/package validation.
- Docker when rebuilding the default `linux-x86_64` Wine userland from the source fork.
- `Amethyst-iOS` checked out next to this workspace, or `IRIDIUM_AMETHYST_ROOT` pointing at that checkout, so app staging can copy `libEGL.framework` and `libGLESv2.framework`.

## Verify the toolchain

Run:

```bash
xcodebuild -version
swift --version
git --version
xcodegen --version
python3 --version
zstd --version
```

Those commands should work without triggering first-run setup or license prompts. If `swift` or `xcodebuild` reports that the Xcode license has not been accepted, fix that before trying to build.

If simulator builds fail because required Xcode components are missing or damaged, run:

```bash
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

## Clone and inspect

```bash
git clone <iridium-repo-url>
git clone <iridium-runtime-sdk-url>
git clone <iridium-fex-ios-url>
git clone <iridium-wine-ios-url>
cd iridium
find apps packages docs scripts -maxdepth 4 -type d | sort
```

Expected top-level working directories in this repo:

- `apps/ios`
- `packages/core`
- `packages/profiles`
- `packages/runtime`
- `docs`

Expected sibling repos beside this one:

- `../iridium-runtime-sdk`
- `../iridium-fex-ios`
- `../iridium-wine-ios`

## Prepare the embedded FEX artifacts

Before validating translator-backed execution or building the iOS app, refresh the canonical embedded FEX artifacts:

```bash
cd ../iridium-fex-ios
./iridium/ios/build_embedded_translator.sh --platform host
./iridium/ios/build_embedded_translator.sh --platform device
./iridium/ios/build_embedded_translator.sh --platform simulator
cd ../iridium
```

These commands populate the canonical manifests and archives used by the native runtime and Xcode linker. The default-root `device` and `simulator` builds also refresh the SDK-specific alias roots `build-iridium-ios-iphoneos` and `build-iridium-ios-iphonesimulator`; the app and test consumers use those SDK-specific aliases rather than relying on `build-iridium-ios-current`.

Swift package resolution no longer aborts merely because unrelated platform archives are absent. A valid host archive enables the translator-backed macOS package path; otherwise that path uses the source fallback. The Xcode app target always expects the matching device or simulator archive so it cannot silently link the source fallback in place of FEXCore.

The Xcode target runs `apps/ios/Scripts/prepare_embedded_translator.sh` and selects `host`, `device`, or `simulator` from `PLATFORM_NAME`. It refreshes the archive when CMake is available, or reuses an existing nonempty archive with a matching canonical manifest. Set `IRIDIUM_REBUILD_EMBEDDED_TRANSLATOR=1` to reject reuse when CMake is unavailable.

## Bootstrap the repo

```bash
./scripts/doctor.sh --bootstrap
./scripts/bootstrap.sh
```

This verifies the expected sibling-repo workspace layout, checks the local toolchain and canonical FEX manifests, verifies the package graph, and generates `apps/ios/Iridium.xcodeproj` from `apps/ios/project.yml`.

If bootstrap fails before Swift package resolution starts, confirm that these sibling repos exist beside this repo:

- `../iridium-runtime-sdk`
- `../iridium-fex-ios`
- `../iridium-wine-ios`

If translator-backed validation or the Xcode link fails, rerun the canonical embedded FEX build command for the affected platform and verify its manifest with `scripts/doctor.sh`.

Before an app build that stages the bundled runtime, run:

```bash
./scripts/doctor.sh --app-build
```

That additionally checks the canonical runtime bundle at `../iridium-runtime-sdk/build/iridium-runtime-base` and the `Amethyst-iOS` framework inputs used by `apps/ios/Scripts/stage_runtime_userland.sh`.

If you only want to regenerate the Xcode project after the environment is already healthy, run:

```bash
./scripts/generate-project.sh
```

## Validate the workspace

From the repo root:

```bash
swift test
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'platform=iOS Simulator,name=<available-simulator-name>' test
```

Use any locally available iPhone/iPad simulator that satisfies the current deployment target. If you need to discover valid simulator names first, run:

```bash
xcrun simctl list devices available
```

Those are the repo-level validation commands and should stay green after each slice in the main repo. Rebuild the canonical embedded FEX artifacts first whenever the bridge code or embedded archive inputs change.

## Current contribution flow

The recommended first steps are:

1. Read [Architecture](architecture.md) and [Roadmap](roadmap.md).
2. Confirm whether the work belongs in `profiles`, `runtime`, `core`, or the iOS app shell.
3. Put native host and engine-port work in the sibling runtime repos instead of forcing it into the SwiftUI shell.
4. Prefer extending existing package seams before inventing new ones.
5. Update docs when the implementation changes the plan.

## Current milestone

The repo is no longer just a thin scaffold:

- Root package manifest is present.
- `core` includes a persisted snapshot store, import-first library state, prefix lifecycle, pending-launch truth, launch history, and runtime-health state.
- `runtime` and `profiles` provide the shared runtime, host-capability, launch-planning, and compatibility seams.
- Runtime health and launch readiness now surface the exact embedded-host blocker instead of generic placeholder validation text.
- An iOS app target spec and SwiftUI shell exist in `apps/ios`.
- `../iridium-runtime-sdk` owns the native host contract and runtime-bundle assembly path.
- `../iridium-fex-ios` and `../iridium-wine-ios` own the source forks for the iOS engine port.
- The FEX iOS bridge now has a real in-process ELF guest loader: PT_LOAD mapping, relocations, amd64 System V process image, and FEXCore ExecuteThread() dispatch. Embedded host tests pass.

The active blockers are now beyond the local structural readiness gate: broader Wine-grade syscall/signal/exception/process/thread behavior, full runtime TLS/thread setup, and physical-device proof of one launched Windows executable. See [Phase 2 Completion Audit](phase-2-completion-audit.md) for the current evidence checklist and the remaining Phase 2C exit criteria.
