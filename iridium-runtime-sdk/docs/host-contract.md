# Host contract

This contract belongs to the retained embedded backend. iOS embeds the host core;
`runtime-host.bin` is its CLI/macOS harness. Definitions live in
[`iridium_runtime_host_contract.hpp`](../src/iridium_runtime_host_contract.hpp)
and the [public C API](../include/public/iridium_runtime_host_c_api.h).

## Files

Required CLI options are `--launch-package`, `--session-update`,
`--terminal-result`, `--telemetry`, and `--host-log`, each followed by a path.

The input matches `RuntimeBackendLaunchPackage`: `id`, `gameTitle`,
`executablePath`, `runtimeBundleRootPath`, and `directLaunchOnly` are required.
Forward `launchArguments` after the selected executable in guest argv.

Outputs match `RuntimeBackendSessionUpdate`, `RuntimeBackendTerminalResult`,
and `PerformanceTelemetrySnapshot`. Omit telemetry when measurements are absent.
Write `host-capabilities.json` at `<runtimeBundleRootPath>/../../`.

## Readiness

The capability record includes `jitStatus`, `deviceCapabilityClass`, `deviceTier`,
`translatorPresent`, `launchReady`, `translatorReady`, `runtimeHostVersion`,
`supportedArchitectures`, `supportedGraphicsAPIs`, and `measuredAt`.

`translatorReady` reflects launch readiness, not file presence. Unknown device
metadata can be null. Required debugger bootstrap or an unavailable syscall bridge
keeps `launchReady=false` with a concrete `launchStatusSummary`. Registered
render/input/audio services must remain live for playability readiness.

Wine userland must preserve its ELF loader, PT_INTERP interpreter, Linux library
paths, and prefix seed. A preloader needs a sibling Unix Wine companion. The
bridge loads that companion with `WINELOADERNOEXEC=1`. High-address Wine shared
data needs the matching rebuilt userland; diagnostic binary patches are insufficient.

The native host wineserver hook is a host-only smoke path. Synthetic terminal
status and `IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE=1` are development overrides,
not product acceptance. The retained backend is direct x64/OpenGL only, without
a desktop, installer flow, WoW64, or kernel-driver support.
