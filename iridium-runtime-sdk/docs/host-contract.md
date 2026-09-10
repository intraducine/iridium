# Native Host Contract

`runtime-host.bin` is the native process that the Iridium app/runtime layer launches for bundled-device execution.

On iOS, the app embeds the host core library in-process. `runtime-host.bin` remains the CLI and macOS harness entrypoint that mirrors the same contract.

## CLI

Required arguments:
- `--launch-package <path>`
- `--session-update <path>`
- `--terminal-result <path>`
- `--telemetry <path>`
- `--host-log <path>`

## Inputs

The host reads the launch package JSON written by Iridium. The current required fields are:
- `id`
- `gameTitle`
- `executablePath`
- `runtimeBundleRootPath`
- `directLaunchOnly`

The host may read the broader package payload as the runtime grows, but it must remain compatible with the existing `RuntimeBackendLaunchPackage` shape in the app repo.

`launchArguments` are part of the embedded direct-launch contract. The host must
pass them through to `IridiumFEXIOSLaunchPaths` so the FEX/Wine bridge builds
guest argv as:

```text
wine-or-loader <selected executable> <launchArguments...>
```

## Outputs

The host writes:
- `session-update` JSON matching `RuntimeBackendSessionUpdate`
- `terminal-result` JSON matching `RuntimeBackendTerminalResult`
- `telemetry` JSON matching `PerformanceTelemetrySnapshot`
- `host-log` text output

No new provider-style transport is introduced. The app repo continues to decode the same JSON shapes it already owns.

## Host Capability Record

The host also writes `host-capabilities.json` into the managed root derived from `runtimeBundleRootPath`:

```text
<runtimeBundleRootPath>/../../host-capabilities.json
```

That record is consumed by Iridium's `FileSystemHostCapabilityProvider` and should include:
- `jitStatus`
- `deviceCapabilityClass`
- `deviceTier`
- `translatorPresent`
- `launchReady`
- `translatorReady`
- `runtimeHostVersion`
- `supportedArchitectures`
- `supportedGraphicsAPIs`
- `measuredAt`

Compatibility notes:
- `translatorReady` remains for backward compatibility and now reflects launch readiness, not mere artifact presence.
- `translatorPresent` distinguishes “translator file exists” from “embedded launch is actually ready.”
- `deviceCapabilityClass` and `deviceTier` may be `null` when the host has no honest value to report.
- `jitToolBootstrapRequired`, `jitToolBootstrapKind`, and `jitToolBootstrapSummary` are surfaced when a debugger-backed helper still needs to prepare executable regions. The host must keep `launchReady = false` and report a concrete `launchStatusSummary` until that helper bootstrap actually completes.
- If the embedded FEX bridge reports that its iOS syscall bridge is unavailable, the host must keep `launchReady = false` even when `jitStatus = ready`, fail launch before guest execution, leave telemetry absent, and surface the concrete bridge summary in capability, session, and terminal failure output.
- Userland smoke checks and runtime-host bootstrap must treat `wine-preloader` as a validation artifact that requires a sibling Unix-side `wine`/`wine64` ELF companion. If that companion declares PT_INTERP, the archive must also include the interpreter at the guest path such as `lib64/ld-linux-x86-64.so.2`. Preloader-only userland roots are invalid. The embedded FEX bridge loads the companion Wine binary directly, maps its PT_INTERP interpreter from the userland root, and sets `WINELOADERNOEXEC=1` so Wine does not re-exec through the preloader path.
- The canonical Wine producer is responsible for including Linux shared-library dependencies reported by `ldd`; the runtime archive must preserve guest paths such as `lib/x86_64-linux-gnu` and `usr/lib/x86_64-linux-gnu` when present.
- Non-smoke embedded launches must account for Wine's Windows shared-data page.
  On arm64 Darwin hosts with a 4GB `__PAGEZERO` reservation, the default
  `0x7ffe0000` mapping fails with `ENOMEM`; the FEX bridge now selects a
  high-address `IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS` fallback for Wine builds
  that support it. Host packaging must use a rebuilt Wine userland that contains
  that fallback; generated binary patches are only valid for local diagnosis.
- A deterministic MinGW x64 `exit0.exe` now completes repeatedly under embedded
  FEX on the arm64 Darwin host without simulators or test devices when the
  guarded native host `wineserver` hook is enabled. The path drives Unix
  socket/message/pipe exchange and architecture negotiation, initializes valid
  Wine syscall frames and a guarded fallback user stack, preserves relocated
  main-image success (`STATUS_IMAGE_NOT_AT_BASE`), avoids the `start.exe`
  process-creation fallback, and records completed terminal results. The hook is
  a host-only smoke gate and must not be treated as the final iOS process model.

## Telemetry

Telemetry is optional. The host writes the telemetry JSON only when concrete metrics are available; otherwise it leaves the telemetry file absent instead of emitting synthetic placeholder values.

## Development Overrides

- `IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE=1` enables the external Wine fallback for development only.
- `IRIDIUM_HOST_ALLOW_SYNTHETIC_TERMINAL_STATUS=1` plus `IRIDIUM_HOST_TERMINAL_STATUS=<state>` may be used for development harnessing only.
- Product acceptance for Phase 2C must not rely on these overrides.

## First-Milestone Rules

- x64 only
- direct executable launch only
- OpenGL only
- no desktop shell
- no launcher shells
- no installer flows
- no x86/WOW64
- no anti-cheat or kernel-driver support
