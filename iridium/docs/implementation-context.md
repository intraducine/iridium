# Implementation Context

This document is the compact-resilient handoff for `/path/to/iridium`.
Paths below intentionally use `/path/to/...` placeholders so the handoff stays portable across workspaces.

Update it when a meaningful runtime/store slice lands or when the active target changes.
Treat the repo-state fields below as a point-in-time snapshot that should be refreshed with each handoff update.

## Current repo state

- Repo path: `/path/to/iridium`
- Branch: `main`
- Snapshot basis: pushed Phase 2 no-device playability-contract and completion-audit slice on `main`.
- Last verified sibling heads: `c9d7781` (iridium-fex-ios), `403021e` (iridium-wine-ios), `42ee7f1` (iridium-runtime-sdk)
- As of 2026-05-01, this handoff includes the pushed no-device playability-contract slice, acceptance-report host snapshot updates, warning cleanup, Phase 2 completion audit, StikDebug skip-probe launch fix, and this non-recursive handoff refresh.

### 2026-07-13 JIT and build correction

- Physical iOS now defaults to the debugger-owned split RX/RW allocator. The MAP_JIT backend is an explicit comparison/private-capability path, not the default sideloaded-app path.
- TXM and OS version are separate runtime capabilities. On iOS 26, StikDebug enables the persistent `brk #0xf00d` callback for iPhone model 14,2 or newer and iPad model 14,5 or newer. On iOS 27, its current policy enables TXM handling on every supported model except `iPad8,11` and `iPad8,12`. Iridium mirrors that policy so non-TXM devices never execute an unhandled TXM breakpoint.
- On TXM devices, each real FEX executable view is prepared through the StikDebug-compatible `brk #0xf00d` command before its writable alias is created. Iridium records the requested provider, targets the current PID, and fails before the breakpoint when the persistent StikDebug callback is absent or detached. A plain AltJIT, JitStreamer, or SideStore attach is insufficient for this TXM-specific path.
- Readiness no longer reports success without performing a real allocation and write. Device execution may be skipped to avoid a destructive probe, but allocation/write evidence is mandatory.
- Iridium no longer clears task/thread exception ports during normal debugger-backed launch; doing so disconnects the helper that owns JIT preparation. The legacy exception-port guard is diagnostic opt-in only.
- The app entitlements match the sideloaded UTM-style model (`extended-virtual-addressing` and `increased-memory-limit`) instead of declaring the macOS-oriented `com.apple.security.cs.allow-jit` entitlement.
- Host, `iphoneos`, and `iphonesimulator` FEX archives build from the pinned dependency set. The runtime SDK and app package graphs build without requiring every platform manifest merely to resolve the package.
- Runtime bundle `2026.07.13-txm-provider` contains the rebuilt capability-driven translator artifact. Physical first-frame proof is still required; this source/build validation does not claim that the remaining Wine-grade syscall, TLS, thread, signal, graphics, and audio work is complete.

Apple's iOS 27 and Xcode 27 release notes do not document a general sideloaded-app JIT entitlement or an app-only bypass for signing/debugger requirements. `get-task-allow` and an external debugger remain the relevant supported debugging boundary. StikDebug 3.1.6 specifically changed TXM detection for A13/A14/M1 devices on iOS 27 and states that target apps also require their own patches. Sources: [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes), [Apple debugger entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger), [StikDebug 3.1.6](https://github.com/StephenDev0/StikDebug/releases/tag/3.1.6), and [StikDebug's iOS 27 TXM detector change](https://github.com/StephenDev0/StikDebug/commit/ef5e962b381edc3348d34f219ef9352cec49ec26).

## Verified commands

Run these from `/path/to/iridium`:

```bash
/path/to/iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform host
/path/to/iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform device
/path/to/iridium-fex-ios/build-iridium-ios-host/Bin/iridium-fex-ios-embedded-tests
swift test
xcodebuild -project /path/to/iridium/apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
/path/to/iridium-runtime-sdk: swift test
/path/to/iridium-wine-ios/iridium/ios/build/bridge_tests
/path/to/iridium-wine-ios/iridium/ios/tests/package_tests.sh
```

These commands were last explicitly reverified against `3ceea6e2583d9fb0203a1188ccab3b095157defb` (iridium), `705345a1d8ab101aa53f419cee8cfedb5ada8812` (iridium-fex-ios), `206b43894ad3f48e347fa75fdf99831f3e3d1c22` (iridium-wine-ios), and `cabb40a7d3fae2b1bf0dd57981ef50c34547fdaa` (iridium-runtime-sdk) on `2026-04-01`.
For the 2026-05-01 runtime/JIT bring-up slice, verification intentionally avoided simulators and test devices. Host verification used the embedded FEX host suite, the runtime SDK embedded host build, SwiftPM host build, and a non-smoke Windows executable launch through `runtime-host.bin`.
For the 2026-05-01 no-device playability-contract slice, local verification includes `swift test --filter IridiumRuntimeTests/testNativeRuntimePlayerRegistryDrivesFilesystemPlayabilityReadiness`, full `swift test`, and `xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` in the main repo; full `swift test` in `iridium-runtime-sdk`; `iridium/ios/build/bridge_tests` plus `iridium/ios/tests/package_tests.sh` in `iridium-wine-ios`; and `/path/to/iridium-fex-ios/build-iridium-ios-host/Bin/iridium-fex-ios-embedded-tests` in `iridium-fex-ios`. The focused main-repo test proves the native runtime player registry can drive filesystem host capability refresh to `playabilityReady = true` only while render/input/audio services are live for the active session. The runtime SDK suite proves registry lifecycle, liveness, second-session rejection, and host log transitions. The Wine bridge/package checks prove the file-backed `wineios.drv` bridge helpers, input/framebuffer round trip, iPhone audio state gating, prefix seed, driver selection, and userland package contract. The FEX host test binary exits 0 for the current embedded host slice, but this remains host-only evidence rather than physical-device execution proof.
For the 2026-05-01 StikDebug device-log triage slice, `/path/to/iridium-fex-ios/build-iridium-ios-host/Bin/iridium-fex-ios-embedded-tests` passes after rebuilding the host test target. The device log showed StikDebug made JIT ready (`p_traced=true`, `host_jit_status=ready`, `allocator_backend=split-rx-rw-debugger`) but `iridium_fex_ios_start_guest_execution` still rejected launch as `jitNotReady` because the skipped execution probe was mislabeled as Xcode-only. `iridium-fex-ios` now keeps actual Xcode launches fail-closed while allowing ready debugger-backed skip-probe sessions to reach guest execution startup.
The Phase 2 completion audit is recorded in `/path/to/iridium/docs/phase-2-completion-audit.md`. It confirms the local structural readiness gate is covered, but Phase 2C remains incomplete until a physical iPhone run proves first frame, guest input, guest audio, and real `launchReady` plus `playabilityReady` without development-only overrides. Current Xcode tooling sees the known iPhone/iPads as offline or unavailable, so the physical-device acceptance run is externally blocked from this workspace.

## Product constraints

- Iridium is an iOS-native Windows-game runtime shell.
- No Windows desktop shell may ever be exposed.
- Manual import is the only shipped acquisition path right now.
- The shipped app should start empty; no seeded titles, downloads, or preview Steam state should appear on first launch.
- Users should only need to provide game files; the app should ship and provision its runtime itself.

## Workspace shape

The runtime work is now multi-repo:

- app/store/runtime shell:
  - `/path/to/iridium`
- native host SDK and runtime-bundle assembly:
  - `/path/to/iridium-runtime-sdk`
- source-owned FEX fork and iOS embedding bridge:
  - `/path/to/iridium-fex-ios`
- source-owned Wine fork and iOS userland/direct-launch bridge:
  - `/path/to/iridium-wine-ios`

## Current architecture

### `packages/core`

Owns durable truth:

- game library state
- prefixes and runtime bundle attachment
- runtime health
- launch history
- verification and compatibility evidence
- activity feed
- pending launches and queued-resume lifecycle

Primary files:

- `/path/to/iridium/packages/core/Sources/IridiumCore/Services.swift`
- `/path/to/iridium/packages/core/Sources/IridiumCore/DeploymentPaths.swift`

The store owns durable runtime and launch lifecycle truth. `AppViewModel` requests actions and observes state, but it should not assemble launch persistence, pending-launch ownership, or runtime ownership rules itself.

### `packages/runtime`

Owns runtime-side behavior:

- runtime bundle registry and validation
- bundled runtime provisioning into managed storage
- host capability probing
- import scanning and executable ranking
- launch planning
- prefix bootstrap
- local on-device runtime host execution
- acceptance harness coverage

Primary files:

- `/path/to/iridium/packages/runtime/Sources/IridiumRuntime/RuntimeBundles.swift`
- `/path/to/iridium/packages/runtime/Sources/IridiumRuntime/HostCapabilities.swift`
- `/path/to/iridium/packages/runtime/Sources/IridiumRuntime/RuntimeExecution.swift`
- `/path/to/iridium/packages/runtime/Sources/IridiumRuntime/RuntimeHost.swift`
- `/path/to/iridium/packages/runtime/Sources/IridiumRuntime/AcceptanceHarnessService.swift`

The runtime layer now includes acceptance-harness coverage, execution-facing compatibility policy resolution, an explicit runtime backend contract, a bundled runtime payload, bundled-runtime provisioning into managed storage, and a bundled-device runtime backend as the default product/runtime path.

### `packages/profiles`

Owns compatibility profiles, broad-catalog policy defaults, and legacy device-tier-backed tuning metadata.

Primary file:

- `/path/to/iridium/packages/profiles/Sources/IridiumProfiles/Profiles.swift`

### `apps/ios`

Owns the SwiftUI shell and thin orchestration.

Primary files:

- `/path/to/iridium/apps/ios/Iridium/AppViewModel.swift`
- `/path/to/iridium/apps/ios/Iridium/Views/RootTabView.swift`

The app shell is no longer the blocker. Preserve it unless a runtime/store contract truly requires a thin integration change.

### Sibling runtime repos

`/path/to/iridium-runtime-sdk`

- owns the native runtime host SDK
- owns the embedded host core and macOS CLI harness
- owns the runtime-bundle assembly path and manifest metadata

`/path/to/iridium-fex-ios`

- owns the source-owned FEX fork
- owns the iOS embedding bridge surface for translator readiness and execution

`/path/to/iridium-wine-ios`

- owns the source-owned Wine fork
- owns the iOS userland build path and direct-launch bridge surface

## Current landed state

- the shipped app now starts empty and is manual-import-first
- durable library, prefix, launch-history, activity, verification, and pending-launch truth live in `IridiumStore`
- bundled runtime provisioning and validation are in place
- bundled-device runtime execution is the default product path
- the app now exposes JIT-gated launch UX and queued launch resume instead of fake install/download surfaces
- runtime bundle validation enforces a concrete required artifact layout
- the runtime SDK now owns the host contract and runtime-bundle assembly seam
- the sibling FEX and Wine repos now expose source-owned iOS bridge entrypoints
- the bundled-device host path routes through the runtime SDK instead of a pure app-side mock path
- the runtime SDK now exposes a native playable-session service registry through the host C API, with session acquire/release, service registration, service liveness, and host capability readiness derived from the active session state
- the app now owns a fullscreen runtime player path with render/input/audio bridge registration via `NativeRuntimePlayerServiceRegistry`, active player session ownership, and release on dismissal/failure
- local SwiftPM coverage now proves that a real native player-service reservation with live render/input/audio services makes `launchReady = true`, `playabilityReady = true`, and all subsystem readiness statuses `ready`, and that releasing the session returns readiness to missing-service state
- the acceptance harness report artifact now embeds the full host capability snapshot so lab validation notes carry `launchReady`, `playabilityReady`, and subsystem readiness evidence alongside launch/session artifacts
- `docs/phase-2-completion-audit.md` now maps every Phase 2 exit requirement to evidence and explicitly records the physical-device first-playable gap
- the Wine bridge now enforces seeded direct-launch preparation and desktop-shell blocking for bundled userland
- the FEX bridge now performs real runtime initialization and truthful session/terminal reporting instead of synthetic success
- the FEX bridge no longer treats a ready StikDebug debugger-backed skip-probe session as an Xcode-only lightweight check during guest launch startup
- the runtime SDK now reports host capability and terminal outcomes honestly instead of defaulting to placeholder success
- the app now surfaces the concrete embedded-runtime blocker in both `Runtime health` and `Launch readiness` instead of generic validation text
- the bundled app runtime now stages a real Wine userland root into the packaged runtime bundle
- the FEX iOS bridge now has a real in-process ELF guest loader: PT_LOAD segment mapping, per-segment permissions, BSS zero-fill
- `wine-preloader` is now treated as a validation artifact that requires a sibling Unix `wine`/`wine64` companion; embedded execution loads that companion directly, maps its `PT_INTERP` loader from the bundled userland root, and injects `WINELOADERNOEXEC=1` so Wine stays inside the in-process FEX image
- runtime bundle inventory, SDK smoke packaging, runtime-host bootstrap, Wine staging/package scripts, and Xcode staging now enforce the same preloader companion contract before accepting or bundling Wine userland
- if the companion Unix `wine`/`wine64` declares PT_INTERP, the staged root must also contain that interpreter at the guest path, for example `/lib64/ld-linux-x86-64.so.2`
- the Wine Linux x86_64 install producer now stages Linux runtime dependencies reported by `ldd` into the install root before packaging, and the stage/package scripts preserve directories such as `lib/x86_64-linux-gnu` and `usr/lib/x86_64-linux-gnu`
- relocation processing is implemented: RELA/REL tables, JMPREL/PLT, R_X86_64_RELATIVE, R_X86_64_64, R_X86_64_GLOB_DAT, R_X86_64_JUMP_SLOT, x86-64 TLS relocation entries (`DTPMOD64`, `DTPOFF64`, `TPOFF64`), weak symbol handling
- initial process image is built: amd64 System V stack layout with argc/argv/envp/auxv (AT_PHDR, AT_PHENT, AT_PHNUM, AT_BASE, AT_ENTRY, AT_RANDOM, AT_PAGESZ, AT_NULL)
- runtime-host JSON `launchArguments` are now forwarded through the embedded FEX bridge and appended to the guest Wine argv after the selected Windows executable path
- FEXCore context creation, InitCore(), CreateThread(entrypoint, stack), and ExecuteThread() are wired and called
- bridge lifecycle is hardened: stable poll string caches, safe thread teardown, deterministic smoke-mode execution
- debugger-backed helper-bootstrap readiness now fails closed before host fallback readiness; host builds report the concrete helper-bootstrap blocker unless the helper bootstrap is simulated/completed
- host capability refresh now reports `launchReady = true` once the translator is present, JIT is ready, and the embedded minimal syscall bridge is wired
- the embedded FEX path now uses the separately tested minimal Darwin syscall handler for the first Wine/ELF-interpreter syscall subset: file reads (`open`, `read`, `close`), interpreter access (`access`, `openat`, `pread64`, `lseek`), Linux-to-Darwin open flag translation, explicit x86-64 Linux stat packing (`fstat`, `newfstatat`), memory mapping/protection (`mmap`, `mprotect`, `munmap`, `brk`, including Linux `MAP_STACK` as an ignored Darwin advisory flag), Linux directory enumeration (`getdents64`), prefix filesystem setup (`chdir`, `mkdir`, `symlink`), pipes (`pipe`, `pipe2`), Unix socket client calls (`socket`, `connect`, `setsockopt`, `sendmsg`, `recvmsg` with `SCM_RIGHTS` translation), vectored writes (`writev`), diagnostics/process hints (`write`, `prctl(PR_SET_NAME)`, `prctl(PR_SET_VMA/PR_SET_VMA_ANON_NAME)`), uid/gid/process queries, loader startup calls (`getpid`, `getppid`, `gettid`, `set_tid_address`, `set_robust_list`, `clock_gettime`), a non-blocking futex compatibility subset (`FUTEX_WAIT` mismatch/zero-timeout handling and `FUTEX_WAKE`), loader identity/path queries (`uname`, `getcwd`, `readlink`, `readlinkat`), CPU/resource probe fallbacks (`getcpu`, `sched_getaffinity`, `sched_setaffinity`, `rseq`, `prlimit64`), guest exit capture (`exit`, `exit_group`), guest-side signal setup bookkeeping (`rt_sigaction`, `rt_sigprocmask`), limited descriptor control (`fcntl`), Linux ABI `ENOSYS` for unsupported syscalls, and `arch_prctl` FS/GS base operations
- the guest loader now lets unresolved PLT function imports load by patching them to a deterministic guest-side `UD2` trap stub; unresolved strong data symbols still fail closed
- embedded host tests build and pass on host platform
- iOS embedded-FEX slice selection is now SDK-specific: Xcode app builds link `build-iridium-ios-iphoneos`, simulator test bundles link `build-iridium-ios-iphonesimulator`, and host SwiftPM paths continue to use `build-iridium-ios-host`
- local Xcode package evaluation does not expose destination-specific environment to `Package.swift`, so `iridium-runtime-sdk/Package.swift` validates the canonical host/device/simulator manifests while the app and test consumers own per-SDK iOS selection in destination-aware build settings
- clean simulator runtime provisioning is green again after switching bundled-runtime directory copy semantics back to a direct recursive copy
- all four sibling repos have committed `HEAD`s on `main`, pushed to GitHub

What is not landed:

- a real playable iPhone Wine/FEX engine
- a physical-device proof that one imported Windows executable runs through the bundled local path
- a physical-device proof that the app runtime player receives the first guest frame, guest input, and initialized guest audio from a Windows title
- syscall bridge: a deterministic MinGW x64 `exit0.exe` now completes repeatedly through embedded FEX/Wine on the arm64 Darwin host with the guarded native host `wineserver` hook; broader apps still need the complete Wine-grade signal/exception/process/thread surface
- arm64 Darwin host proof now uses a high-address Wine shared-data fallback for the `0x7ffe0000` pagezero conflict, relocates the first TEB reservation out of the low 4GB range, initializes valid Wine syscall frames and a guarded fallback user stack, and treats `STATUS_IMAGE_NOT_AT_BASE` as a successful relocated main image instead of falling back through `start.exe`
- dynamic symbol resolution for external imports (weak/undefined symbols resolve to 0; no full PLT trampoline)
- full runtime TLS block/thread setup beyond static TLS relocation handling
- stale on-device runtime cache invalidation (device may reuse a cached bad userland layout)

## Active target

The active target is getting the first actual Windows executable to run on-device through the bundled local runtime path.

Work should focus on:

- driving the embedded FEX path from bootstrapped guest load to a proven on-device execution result in `/path/to/iridium-fex-ios`
- wiring the remaining syscall, external symbol, and TLS bring-up on top of the now-honest embedded runtime session path
- keeping `/path/to/iridium-wine-ios` aligned with the bundled direct-launch contract and seeded prefix path
- using `/path/to/iridium-runtime-sdk` to assemble and host those pieces without changing the main app contracts
- proving one imported Windows executable can launch through the bundled local path on physical device
- preserving store-owned durable truth while avoiding new UI-owned lifecycle state

Current concrete blockers:

- The physical-device app/runtime path now validates honestly and can report `launchReady = true` when the translator, JIT, and minimal syscall bridge are present.
- The local playability contract can now report `playabilityReady = true` when the active playable session has live render, input, and audio services registered through the runtime SDK. This is a structural no-device gate, not proof that a real title renders on iPhone.
- A debugger-backed StikDebug bootstrap-required state must not be treated as `Runtime ready.` by the host fallback; it remains `jitBootstrapRequired` until the helper bootstrap actually completes.
- A ready StikDebug debugger-backed session must not be mislabeled as Xcode-attached merely because the unsafe execution probe was skipped on iOS; `iridium-fex-ios` now uses a non-Xcode skip-probe stage label and only blocks actual Xcode debug launches.
- Simulator/device FEX slice selection is no longer the blocker: the verified matrix now resolves `build-iridium-ios-host`, `build-iridium-ios-iphoneos`, and `build-iridium-ios-iphonesimulator` explicitly and passes.
- `iridium-runtime-sdk` now stages a real Wine userland root into the bundled runtime, so the remaining blockers are below payload assembly and build-time slice selection in the embedded FEX/Wine execution path itself.
- The unresolved execution blockers are now beyond the deterministic host smoke path: complete Wine-grade signal/exception/syscall coverage, broader process/thread behavior, and full runtime TLS/thread setup for real applications. The current path enters embedded FEX/Wine, loads through `PT_INTERP`, suppresses the Wine preloader re-exec path, maps Wine shared data via the high-address fallback, allocates valid Wine syscall frames, maps the target PE directly, and no longer falls back through `start.exe` on `STATUS_IMAGE_NOT_AT_BASE`.
- A deterministic x64 Windows `exit0.exe` built with local MinGW now completes on the arm64 Darwin host without simulators or test devices when the guarded native host `wineserver` hook is enabled. The latest verification completed 12 consecutive untraced runs under `/tmp/iridium-runtime-exit0-stackbasefix-*`; this is a host-only smoke gate and is not the final iOS process model.
- Physical-device proof remains blocked in this environment because no attached iPhone/iPad lab target, no external JIT-enable path, and no licensed validation title are available from this workspace alone.

## Current workspace delta

- The main repo is on `main` with the pushed no-device playability-contract slice, acceptance-report host snapshot updates, and Phase 2 completion audit.
- The runtime workspace now spans four sibling repos:
  - `/path/to/iridium`
  - `/path/to/iridium-runtime-sdk`
  - `/path/to/iridium-fex-ios`
  - `/path/to/iridium-wine-ios`
- The runtime SDK compiles source-owned Wine/FEX bridge seams directly and remains the assembly point for the bundled runtime path.
- The SDK workspace now stages a bundled Wine userland root into the iOS app bundle instead of relying on on-device extraction for the app-shipped runtime.
- Local Swift package manifests under Xcode still do not receive destination-specific environment, so per-SDK iOS FEX selection lives in consumer build settings while `iridium-runtime-sdk/Package.swift` validates the canonical host/device/simulator manifests.
- The host/runtime contract now reports `launchReady`, `launchStatus`, and `launchStatusSummary`, and the SwiftUI shell surfaces those values directly in runtime-health and launch-readiness UI.
- The host/runtime contract also reports `playabilityReady`, `presentationReadiness`, `inputReadiness`, and `audioReadiness` from the active playable-session service registry when a session is reserved and live.

## Remaining synthetic seams

- `DevelopmentRuntimeBackendClient` remains the explicit simulator/macOS/harness fallback
- the bundled-device host path now routes through the runtime SDK host contract, but the physical-device execution proof is still missing
- provider-backed execution still exists in-repo as an explicit internal override for debugging and bridge-host processing
- Steam product UI is intentionally hidden until it can converge on the same bundled local runtime path with real catalog and transfer state
- the canonical fork-assembly path itself is now wired and fail-closed, but the embedded FEX bridge still blocks before true guest execution

## Steam status

- Keep the current bridge/store Steam architecture in place as internal scaffolding only
- Steam launch must eventually converge into the same bundled local runtime path used by manual imports
- Do not reopen Steam product UI until the local runtime path is real

## Guardrails

- Use `apply_patch` for manual edits
- Do not revert unrelated user changes
- Keep package tests, simulator tests, and generic iOS build green after each slice
- Commit small vertical slices only after verification passes
