# First Playable iPhone Runtime Plan

This document exists to close the gap between “the app no longer crashes” and “the app can actually run a game on a physical iPhone.”

It is intentionally narrower than the general roadmap. The roadmap records project direction. This document records the concrete engineering work required to make the bundled-device runtime become genuinely playable on iPhone.

The plan is complete only when the ending condition at the bottom is satisfied exactly.

## 1. Current truth

The current state is structurally closer to playable, but physical-device playability is still unproven:

- JIT checks no longer crash the app.
- Unsafe launch attempts no longer proceed into known-bad execution paths.
- The app correctly blocks direct launch when runtime health is below playable.
- The bundled-device runtime host can truthfully report `jitStatus = ready`.
- The runtime SDK has an active playable-session service registry for render, input, and audio service liveness.
- The app has a fullscreen runtime player path that registers render/input/audio bridge handles with that native registry.
- Local tests prove the host capability snapshot can become `playabilityReady = true` from live session-bound services and returns to missing-service state after release.
- No physical iPhone run has proven that a Windows executable renders a first frame, receives input, or initializes audio through the bundled local runtime path.

The current blocker is not JIT detection or the absence of a service registry. The blocker is proving the registry-backed app/player/Wine/FEX path against a real title on physical iPhone hardware.

## 2. Problem statement

The iPhone product path still lacks physical proof of all of the following:

1. A Wine runtime driver path that can own a fullscreen iPhone guest window and feed it input.
2. A guest render path that swaps into the app runtime player surface on device.
3. A guest audio path that initializes iPhone output for the first title.
4. A long-lived interactive runtime session proven on physical hardware.
5. Enough guest-runtime correctness to let one lightweight title stay in `.running`.

As long as any one of those is missing, the app may be stable, but it does not “work” in the product sense.

## 3. Scope and non-goals

This document is only for the first playable iPhone runtime milestone.

In scope:

- physical iPhone only
- bundled-device backend only
- one active fullscreen playable session at a time
- one lightweight x64/OpenGL title as the first acceptance target
- `GraphicsStack.metalOpenGLFallback` only
- touch, controller, and keyboard input only
- audio output only

Out of scope for this document:

- iPad-specific UX or multitasking behavior
- multiple guest windows
- desktop shell support
- mouse cursor fidelity beyond what is needed for the first title
- microphone or capture input
- DXVK / VKD3D / Vulkan path completion
- broad title compatibility
- Steam-specific launch/install work

## 4. Architecture decision

The first playable implementation must use the existing bundled-device architecture instead of inventing a second system:

- the runtime host continues to run inside the app process on iPhone
- the app continues to launch through the bundled-device backend
- the runtime host remains the source of truth for launch/bootstrap/readiness
- the playability layer is added as an in-process host service registry, not as a new external daemon or transport

This is the correct boundary because the current bundled-device backend already launches the embedded runtime host inside the app process on iPhone. That makes in-process UIKit, GameController, and audio integration the lowest-risk path.

## 5. Required workstreams

### Workstream A: Runtime host service registry

Owner repo:
- `iridium-runtime-sdk`

Goal:
- make the runtime host capable of reporting real presentation/input/audio readiness based on actual live services bound to a real runtime session

Required changes:

1. Add an iOS-only runtime host service registration API.
   - Keep the existing host C API for launch and capability refresh.
   - Add a separate internal registration surface for render/input/audio services.
   - Registration must be process-global and single-session for v1.

2. Add an active-session service registry.
   - Registry key is runtime session ID.
   - Registry stores:
     - render service handle
     - input service handle
     - audio service handle
     - liveness/session-binding metadata
   - Only one session may own the registry at a time in v1.
   - Starting a second playable session must fail with a clear runtime-host error.

3. Replace placeholder readiness computation in `runtime_host_core.cpp`.
   - Original behavior used env-only override hooks and otherwise defaulted to missing-service placeholders.
   - Landed behavior is:
     - `launchBlocked` when embedded launch bootstrap is not ready
     - `presentationServiceMissing` only when no live render service is registered for the session
     - `inputBridgeMissing` only when no live input service is registered for the session
     - `audioBridgeMissing` only when no live audio service is registered for the session
     - `ready` only when the corresponding service is live and bound to the active session

4. Keep file contracts stable.
   - `host-capabilities.json` field names remain unchanged.
   - `presentationReadiness`, `inputReadiness`, and `audioReadiness` stay the source of truth.

5. Add explicit host-log lines for service lifecycle.
   - session acquired
   - render service registered
   - input service registered
   - audio service registered
   - session released
   - service liveness failure

Acceptance for Workstream A:

- host capability refresh shows real subsystem readiness based on live registration, not placeholder defaults
- second active playable session is rejected
- host logs show service registration and release transitions for the session

Status:
- Landed at the host/app contract level. The runtime SDK exposes the active session registry and the app uses `NativeRuntimePlayerServiceRegistry`; local coverage verifies readiness and release behavior. Device-backed service usefulness remains part of the final hardware validation.

### Workstream B: Interactive runtime session model

Owner repos:
- `Iridium`
- `iridium-runtime-sdk`

Goal:
- stop treating a successful launch as “host returned terminal state” and instead support a long-lived running session suitable for gameplay

Required changes:

1. Keep the current `RuntimeSessionExecutor` API shape for now.
   - Do not rename it in this milestone.
   - Change semantics so success means:
     - the runtime host entered `.running`
     - the session became player-owned
   - Terminal completion/failure must be observed asynchronously after handoff.

2. Change runtime backend/session monitoring behavior.
   - Current code waits for terminal state and is shaped like a validation harness.
   - New first-playable behavior must:
     - accept `.running` as a successful launch handoff
     - continue monitoring the session after handoff
     - feed terminal completion/failure back into app state and launch history

3. Add explicit running-session ownership in the app.
   - The app must know which runtime session owns the player at any moment.
   - Backgrounding, dismissal, and terminal session failure must release ownership cleanly.

4. Preserve current blocking rules.
   - The app may not present the player unless:
     - `launchReady == true`
     - `playabilityReady == true`
     - `session.readiness == .ready`

Acceptance for Workstream B:

- app can enter a running interactive session without waiting for process exit
- session transitions from `.running` to `.completed` or `.failed` update UI and history without crashing or orphaning the session

Status:
- Partially landed. The app has explicit runtime player session ownership and release paths. Physical-device running-session behavior remains unverified.

### Workstream C: Runtime player screen

Owner repo:
- `Iridium`

Goal:
- create the actual fullscreen player surface the user sees once the runtime enters `.running`

Required changes:

1. Add a dedicated runtime player screen.
   - Fullscreen only.
   - Presented from the launch flow after runtime handoff.
   - Not embedded in the library list/detail UI.

2. Add a native render host view.
   - Backed by the native layer suitable for the first graphics path.
   - V1 target is the `metalOpenGLFallback` stack only.
   - The player owns this surface for the active session only.

3. Add runtime input routing.
   - Touch events from UIKit
   - Controller input from `GameController`
   - Keyboard input when attached
   - Pointer/mouse synthesis only as needed for the first title

4. Add runtime audio session ownership.
   - Player lifecycle owns activation/deactivation for the app-side audio session hooks required by the host/audio driver path.

5. Update launch UX wording.
   - “Launch succeeded” must mean “entered running session.”
   - Blocked launches remain blocked.
   - Completed/failed sessions must dismiss the player or surface a failure state without returning to the old crash behavior.

Acceptance for Workstream C:

- a real fullscreen player screen appears only after a runtime session enters `.running`
- blocked states never present the player
- terminal failures dismiss cleanly and leave history/activity coherent

Status:
- Structurally landed in the app with a fullscreen runtime player and bridge handles. First-frame rendering, input delivery, and audio behavior from a real Windows title remain unverified on device.

### Workstream D: Wine iOS runtime driver

Owner repo:
- `iridium-wine-ios`

Goal:
- create the first actual iPhone runtime driver for fullscreen guest windows and input

Decision:
- create `wineios.drv`
- derive it from `wineandroid.drv` concepts, not from `winemac.drv`

Reason:
- the first iPhone target is single-surface, fullscreen, touch-oriented, and app-contained
- that fits the Android driver’s shape better than AppKit’s multiwindow model

Required changes:

1. Create `wineios.drv`.
   - Fullscreen only
   - Single active guest surface
   - No desktop shell
   - No floating windows
   - No taskbar/window-manager behavior
   - Child/modal windows may exist logically but are composited into the same host surface

2. Reuse/adapt from `wineandroid.drv`.
   - single desktop/client surface ownership model
   - event queue model
   - window lifecycle model
   - keyboard/input translation structure
   - OpenGL drawable/swap plumbing

3. Define the host surface bridge used by `wineios.drv`.
   - `wineios.drv` must be able to attach to the runtime player’s active native surface
   - the driver may not fabricate its own hidden or fake surface path

4. Define input translation.
   - UIKit touch -> Wine mouse/touch events
   - GameController -> Wine key/button axis events
   - keyboard -> Wine keyboard events

5. Wire the runtime host to select `wineios.drv` on device for this path.
   - Do not depend on `winemac.drv` for iPhone.
   - Do not claim readiness unless `wineios.drv` is the actual driver in use for the first-playable target.

Acceptance for Workstream D:

- `wineios.drv` can create the first fullscreen top-level guest window
- OpenGL swap reaches the host player surface
- input events reach the guest through the driver

### Workstream E: Audio path

Owner repo:
- `iridium-wine-ios`

Goal:
- reuse Wine’s CoreAudio stack for iPhone output rather than inventing a new audio architecture

Required changes:

1. Keep `winecoreaudio.drv` as the baseline.
2. Adapt it for iPhone session behavior.
   - activate/configure `AVAudioSession`
   - choose a playback category suitable for fullscreen game audio
   - handle interruption and route changes
   - keep readiness false until audio can actually initialize a render path

3. Limit v1 scope.
   - output only
   - no microphone/capture

Acceptance for Workstream E:

- audio readiness only flips to ready when the real playback path is live
- the first playable title can initialize audio without crashing or reporting `audioBridgeMissing`

### Workstream F: Graphics stack narrowing

Owner repos:
- `Iridium`
- `iridium-runtime-sdk`
- `iridium-wine-ios`

Goal:
- make the first playable milestone target one graphics path only

Required changes:

1. First playable path is `GraphicsStack.metalOpenGLFallback`.
2. Runtime policy and runtime bundle handling must preserve or force that path for the acceptance title.
3. The runtime player surface and `wineios.drv` only need to support the OpenGL fallback path in this slice.
4. DXVK / VKD3D work is explicitly deferred and may not block the first playable milestone unless the team chooses to change the acceptance title.

Acceptance for Workstream F:

- the first playable title runs through the OpenGL fallback path only
- no DXVK / VKD3D work is required to satisfy this document

### Workstream G: Guest-runtime correctness

Owner repos:
- `iridium-fex-ios`
- `iridium-runtime-sdk`
- `iridium-wine-ios`

Goal:
- keep the execution-correctness work explicit so the playability layer does not create fake readiness

Remaining known work:

- syscall bridge
- dynamic symbol resolution for external Wine imports
- TLS setup
- any other startup/runtime faults that prevent the title from reaching or remaining in `.running`

Rules:

- do not mark the app playable if these still prevent the title from entering the running session
- do not use host-service readiness to hide execution faults

Acceptance for Workstream G:

- one target title can enter `.running` and stay there long enough to satisfy the ending condition

## 6. Repo-by-repo implementation map

### `Iridium`

Must add:

- fullscreen runtime player screen
- active running-session ownership in app state
- render host view
- input routing ownership
- audio session lifecycle ownership
- updated launch success/failure messaging for interactive sessions

Must preserve:

- existing launch gating
- no player presentation while blocked
- existing library/import/prefix flows

### `iridium-runtime-sdk`

Must add:

- iOS host service registration API
- active session/service registry
- subsystem readiness sourced from live services
- running-session handoff model
- host logging for service lifecycle

Must preserve:

- `host-capabilities.json` field names
- existing launch ticket and session record shapes

### `iridium-wine-ios`

Must add:

- `wineios.drv`
- runtime host bridge glue for host surface/input integration
- iPhone-aware `winecoreaudio.drv` session handling

Must preserve:

- direct-launch-only policy
- existing prefix/bootstrap ownership boundary

### `iridium-fex-ios`

Must continue:

- execution correctness work needed to sustain one real running title

Must preserve:

- current crash-prevention and truthful readiness behavior

## 7. Test plan

### Host / SDK tests

- no registry present -> presentation/input/audio missing
- render only -> `playabilityReady == false`
- render + input + audio -> `playabilityReady == true`
- second playable session rejected
- launch still blocked if subsystem readiness is incomplete
- `.running` session is accepted as player handoff, not treated as failure

### App tests

- blocked runtime never presents the player
- ready runtime presents the player
- terminal failure/completion updates UI/history cleanly
- player teardown releases session ownership

### Wine fork tests

- `wineios.drv` creates fullscreen top-level guest window
- OpenGL drawable creation and swap works on the iOS-backed host surface
- touch/controller/keyboard input is delivered to the guest
- `winecoreaudio.drv` can initialize output on iPhone and handle interruptions

### Device tests

Required test environment:

- physical iPhone
- bundled-device backend
- external debugger/JIT workflow currently used for the project
- first title bound to `metalOpenGLFallback`

Required device scenarios:

1. App remains stable during JIT refresh and blocked launch attempts.
2. Host reports:
   - `presentationReadiness = ready`
   - `inputReadiness = ready`
   - `audioReadiness = ready`
   - `playabilityReady = true`
3. Lightweight x64/OpenGL title:
   - renders a first frame
   - responds to touch or controller input
   - initializes audio
   - stays in `.running`
4. Exiting or failing the session returns the app to a sane state without crash or orphaned session ownership.

## 8. Risks and failure modes

This document is not complete unless these are actively handled:

- host/session model still assumes terminal completion before success
- `wineios.drv` cannot bind to the host surface cleanly
- UIKit/GameController input translation is incomplete for the first title
- CoreAudio path initializes on macOS assumptions that do not hold on iPhone
- FEX/Wine correctness bugs still prevent sustained `.running`
- fake readiness appears because services are registered before they are truly usable

Every one of those must be solved in code, not worked around with development-only flags.

## 9. Ending condition

The structural portion of this document has finished serving its purpose only when **all** of the following are true without requiring access to a physical device or simulator:

This structural ending condition is narrower than the roadmap Phase 2C exit gate. Even after this plan is structurally complete, Phase 2C still requires the separate physical-device first-frame/input/audio proof recorded in `docs/phase-2-completion-audit.md`.

1. The codebase contains all required runtime-playability components in the intended repos:
   - an iOS runtime host service registration and active-session registry in `iridium-runtime-sdk`
   - a fullscreen runtime player surface and running-session ownership path in `Iridium`
   - a `wineios.drv` implementation and iPhone-aware `winecoreaudio.drv` path in `iridium-wine-ios`
   - the necessary guest-runtime correctness hooks still tracked in `iridium-fex-ios` / host integration
2. The bundled-device runtime host no longer depends on placeholder subsystem defaults for playability and instead computes:
   - `presentationReadiness`
   - `inputReadiness`
   - `audioReadiness`
   from real registered service state.
3. The launch path is wired so that a successful playable launch means handoff into a long-lived `.running` session, not waiting for an immediate terminal result.
4. The app-side runtime player can only be presented from a fully ready session and owns:
   - render surface lifecycle
   - input routing lifecycle
   - audio session lifecycle
5. The Wine side is wired so the iPhone playable path uses:
   - `wineios.drv` for fullscreen windowing/input
   - `winecoreaudio.drv` for output audio
   - `metalOpenGLFallback` as the first supported graphics stack
6. Automated verification exists for each critical component, even if no device is available:
   - host capability/readiness tests
   - running-session handoff tests
   - app launch/player presentation tests
   - `wineios.drv` and audio-driver tests
   - regression coverage for blocked launch and non-playable states
7. No development-only override, fake readiness bit, or synthetic host status is required for the architecture to claim readiness on paper.
8. A separate manual validation runbook exists that a human can execute later on real hardware to prove first-frame/input/audio behavior, but that manual proof is not required for this document's structural checklist to be considered complete.

If any one of those is not true, this document is still active and its work is not done.
