# Roadmap

This roadmap keeps the project honest: establish the shell and contracts first, then make import/prefix/runtime flows real, then land the actual engine, then widen compatibility without reopening the architecture.

## Phase 0: Repository and package scaffold

- Land the root package graph and the iOS app shell spec.
- Stabilize the `IridiumCore`, `IridiumRuntime`, and `IridiumProfiles` API seams.
- Expand tests around runtime, compatibility, and host-capability mappings.
- Exit when package boundaries are real and contributors have a consistent local bootstrap path.

## Phase 1: Library, import, and prefix vertical slice

- Replace the seeded startup state with durable empty-state persistence.
- Make library registration, manual import, and prefix lifecycle durable.
- Wire the iOS shell to those real services.
- Exit when the app can manage titles and prefixes without any runtime launch path yet.

Status:
- Landed. The repo now starts empty, persists durable JSON snapshot state, and exposes an import-first SwiftUI shell with runtime health, library registration, prefix lifecycle, launch history, and activity state.

## Phase 2: Runtime integration baseline

Phase 2 is no longer one vague block. It now has three explicit sub-phases.

Current blocking truth:
- The iPhone runtime is now stable enough to report honest readiness instead of crashing during JIT checks or blocked launch attempts.
- Embedded launch bootstrap can report `jitStatus = ready` while the app still blocks launch unless a real playable session owns live presentation, input, and audio services.
- The host playability layer now has a local active-session service registry and app-side runtime player bridge, so readiness can be derived from registered render/input/audio services instead of unconditional placeholder defaults.
- The remaining product blocker is physical-device proof that those services are backed by a working Wine/FEX title path:
  - guest rendering must reach the iPhone player surface
  - UIKit/GameController/keyboard input must reach the guest
  - guest audio must initialize through the iPhone output path
- No physical iPhone validation has been performed from this environment, so Phase 2C is not complete even though the local no-device readiness contract is now in place.

### Phase 2A: App/runtime contracts and import-first shell

- empty-first-launch app shell
- durable import, prefix, launch-history, and activity state
- bundled-runtime provisioning and validation
- JIT-gated launch UX and queued launch resume

Status:
- Landed.

### Phase 2B: Embedded host seam and runtime assembly path

- bundled-device backend as the default product path
- runtime SDK owns native host and bundled runtime assembly
- source-owned Wine/FEX forks exist and compile bridge seams
- host capability records flow back into the app/runtime path

Status:
- Landed. The bundled-device backend, runtime SDK host contract, source-owned Wine/FEX bridge seams, and host-capability flow are in place. The remaining work is now the real execution proof tracked by Phase 2C rather than missing Phase 2B architecture.

### Phase 2C: From bootstrap-ready to first playable on-device runtime

- replace placeholder bundled artifacts with a real runtime payload
- replace bridge stubs with a real embedded Wine/FEX execution path
- keep unsafe launches blocked until host playability services are real
- exit only when one imported Windows executable reaches a playable on-device runtime, not merely a truthful bootstrap state

Status:
- Active target. Substantial execution infrastructure landed: the FEX iOS bridge now has a real in-process ELF guest loader (PT_LOAD mapping, permissions, BSS, relocation processing), an amd64 System V initial process image (argc/argv/envp/auxv), and a wired FEXCore execution path (context creation → InitCore → CreateThread → ExecuteThread). Embedded host tests pass. JIT detection and anti-crash launch gating are now stable enough to report truthful runtime state on device. The remaining work is no longer a single “runtime not ready” bucket, so Phase 2C is split into explicit tracks below.
- Validate first-frame, input and audio behavior on a physical device using the [manual validation runbook](manual-validation-runbook.md). Local structural tests do not establish playability.

#### Phase 2C.1: Truthful bootstrap and launch gating

- report embedded runtime truthfully under Xcode and external debugger-backed sessions
- keep lightweight JIT checks cheap and non-crashing
- block direct launch whenever runtime health is below playable
- remove unsafe allocator/runtime fallbacks that can enter SIGBUS-prone execution paths on iPhone

Status:
- Landed. The app now blocks when runtime health is below playable instead of proceeding into JIT code emission. Xcode-attached JIT checks no longer count as proof that the runtime is playable.

#### Phase 2C.2: Real host playability services

- implement an actual iOS presentation service for guest windows and rendered frames
- implement an actual iOS input bridge for touch, controller, keyboard, and pointer events
- implement an actual iOS audio bridge for guest output
- make host capability reporting for presentation/input/audio derive from real service state rather than placeholder defaults or env-only overrides

Status:
- Local readiness contract landed. The runtime SDK owns an active playable-session registry and C API for render/input/audio service registration and liveness. The app now has a fullscreen runtime player path with file-backed render/input/audio bridge handles, and `NativeRuntimePlayerServiceRegistry` drives host capability refresh so `playabilityReady` becomes true only when all three services are live for the active session.

Remaining caveat:
- This is a no-device structural gate, not a product-playability proof. The host/app contract can now report ready from real registered service state, but a physical iPhone still must prove that Wine/FEX renders frames into that surface, receives input, and initializes audio for an imported Windows executable.

#### Phase 2C.3: First playable title on device

- prove one lightweight known-good Windows title renders a first frame on physical iPhone
- prove guest input reaches the title
- prove guest audio initializes cleanly
- keep the app up without the earlier JIT/probe/launch crash paths

Status:
- Active external validation target. Blocked in this workspace by lack of physical-device access, debugger/JIT workflow access, and a licensed validation title. Also still dependent on guest-runtime correctness and Wine driver/audio behavior being good enough for one sustained running title.

#### Track A: Host playability layer

- presentation bridge for guest rendering/window output
- input/event bridge from UIKit and GameController into the guest runtime
- audio output path for the guest runtime
- host capability reporting backed by real subsystem health

#### Track B: Guest runtime execution correctness

- syscall bridge for iOS-backed guest execution
- dynamic symbol resolution for external Wine imports
- TLS setup
- any startup/runtime correctness gaps that remain after launch is unblocked

Acceptance for Phase 2C:
- `launchReady = true`
- `playabilityReady = true`
- `presentationReadiness = ready`
- `inputReadiness = ready`
- `audioReadiness = ready`
- no development-only override is required to claim readiness
- one lightweight Windows title reaches a rendered frame on physical device with working input and initialized audio

No-device readiness gate:
- The local codebase may be considered structurally ready for device validation when automated tests prove the host/app service registry can drive `playabilityReady` from real session-bound render/input/audio liveness, blocked states stay blocked, and the player lifecycle releases ownership cleanly.
- Passing this gate does not complete Phase 2C. The physical-device acceptance above remains the product gate.

## Phase 3: Steam and broader-title support

- Reintroduce real Steam auth, library sync, depot resolution, and on-device installs only after they converge on the same local runtime path used by manual imports.
- Harden compatibility defaults for balanced and performance-oriented workloads.
- Validate controller, touch, and keyboard/mouse flows across the universal app shell.
- Exit when Steam install/update/uninstall and broader launch flows are reliable.

## Phase 4: Heavy-title whitelist and ship blockers

- Land whitelist policy and heavy-title storage/runtime tuning without reintroducing abstract user-visible device-tier gating.
- Make heavy-title support real on the first approved devices.
- Add bounded adaptation and thermal/degradation rules that stay within profile limits.
- Exit when the v1 broad-catalog launch path meets acceptance and the supported-device matrix is explicit.

## Non-goals for the first slice

- Social/community hub surfaces.
- Remote streaming or desktop-shell exposure.
- Anti-cheat-heavy multiplayer guarantees.
- Broad device promises before the real embedded runtime path is proven.
- Reopening the app shell architecture to compensate for missing runtime-engine work.
- Treating debugger-attached or development-only readiness as proof that the product is playable.
