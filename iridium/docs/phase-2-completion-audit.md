# Phase 2 Completion Audit

Date: 2026-05-01

This audit checks the Phase 2 objective against the current workspace evidence. It is intentionally stricter than the local test matrix: Phase 2C exits only when a real imported Windows executable is playable on a physical iPhone.

## Objective

Finish Phase 2 of the Iridium roadmap while keeping the docs current and getting all repos ready for an actual working app. The current workspace has no physical iPhone/iPad available for validation.

Concrete success criteria:

- Phase 2A app/runtime contracts and import-first shell are landed.
- Phase 2B embedded host seam and runtime assembly path are landed.
- Phase 2C truthful bootstrap and launch gating are landed.
- Phase 2C real host playability services are backed by real session-bound presentation, input, and audio service state instead of placeholder readiness.
- Phase 2C first-playable acceptance is proven on a physical iPhone:
  - `launchReady = true`
  - `playabilityReady = true`
  - `presentationReadiness = ready`
  - `inputReadiness = ready`
  - `audioReadiness = ready`
  - no development-only override is required to claim readiness
  - one lightweight Windows title reaches a rendered frame on physical device with working input and initialized audio
- Main and sibling repos are committed, pushed, and clean.
- Docs explain the current state without implying that local proxy gates complete the product milestone.

## Checklist

| Requirement | Evidence | Status |
| --- | --- | --- |
| Phase 2A app/runtime contracts and import-first shell | `docs/roadmap.md` marks Phase 2A landed; existing store/runtime/app tests continue to pass in the full `swift test` matrix. | Landed |
| Phase 2B embedded host seam and runtime assembly path | `docs/roadmap.md` marks Phase 2B landed; sibling repos are present and pushed; generic iOS build and sibling runtime tests have passed for the current no-device slice. | Landed |
| Truthful bootstrap and launch gating | `docs/roadmap.md` marks Phase 2C.1 landed; runtime tests cover JIT readiness, blocked launches, and no unsafe fallback readiness under Xcode-only probing. | Landed |
| Host playability readiness derives from real session state | `packages/runtime/Tests/IridiumRuntimeTests/IridiumRuntimeTests.swift` includes `testNativeRuntimePlayerRegistryDrivesFilesystemPlayabilityReadiness`, proving a native player-service reservation with live render/input/audio handles drives `playabilityReady = true` and release returns readiness to missing-service state. | Landed as a no-device structural gate |
| Acceptance harness records readiness evidence | `AcceptanceHarnessReportArtifact.hostCapabilitySnapshot` is encoded for new reports and optional for legacy report decoding; tests cover deterministic report output and legacy compatibility. | Landed |
| Local verification for app repo | Latest local verification during this slice: full `swift test` passed with 153 tests executed, 2 skipped, 0 failures; generic iOS build passed with `CODE_SIGNING_ALLOWED=NO`. | Passed |
| Local verification for runtime SDK | Latest local verification during this slice: `swift test` in `iridium-runtime-sdk` passed. | Passed |
| Local verification for Wine fork | Latest local verification during this slice: `iridium/ios/build/bridge_tests` and `iridium/ios/tests/package_tests.sh` passed in `iridium-wine-ios`. | Passed |
| Local verification for FEX fork | Latest local verification during this slice: host embedded test binary exited 0 in `iridium-fex-ios`. | Passed as host-only evidence |
| Physical-device availability | `xcrun xctrace list devices` reports the known iPhone/iPads under `Devices Offline`; `xcrun devicectl list devices` reports them as `unavailable`. | Blocked externally |
| User-supplied StikDebug launch log | `/path/to/iridium-runtime.log` showed the redirected StikDebug flow reached `p_traced=true`, `host_jit_status=ready`, and `allocator_backend=debugger-mirrored-rx-rw`; launch still failed before guest execution because `iridium-fex-ios` mislabeled the safe skipped execution probe as Xcode-only. Fixed in `iridium-fex-ios` by keeping actual Xcode launches blocked while allowing ready debugger-backed skip-probe sessions to start guest execution. | Fixed locally; needs rebuilt device artifact and rerun |
| Physical-device first frame | Requires an attached physical iPhone, external JIT/debugger workflow, built device artifacts, and a licensed validation title. No physical-device run has been performed from this workspace because no device is available to Xcode tooling. | Missing |
| Physical-device guest input | Requires the same physical-device session and confirmation that touch/controller/keyboard input changes guest state. No physical-device run has been performed from this workspace because no device is available to Xcode tooling. | Missing |
| Physical-device guest audio | Requires the same physical-device session and confirmation that guest audio initializes through the iPhone output path. No physical-device run has been performed from this workspace because no device is available to Xcode tooling. | Missing |
| No development-only override for product readiness | Local tests prove readiness can come from session-bound services. A real device run must still prove the same readiness while the Wine/FEX title path is actually producing frame/input/audio behavior. | Partially verified |
| Repos committed, pushed, and clean | `iridium`, `iridium-runtime-sdk`, `iridium-wine-ios`, and `iridium-fex-ios` have been checked clean on `main...origin/main` after the no-device readiness commits. | Clean at audit time |
| Docs avoid overclaiming | `docs/roadmap.md`, `docs/manual-validation-runbook.md`, `docs/implementation-context.md`, and `docs/first-playable-iphone-runtime-plan.md` state that local or structural readiness does not complete Phase 2C. This audit records the same blocker explicitly. | Landed |

## Conclusion

Phase 2 is not complete.

The codebase is locally ready for physical-device validation of the first-playable path, and the no-device structural readiness gate is covered by automated tests. The missing acceptance evidence is the product gate: a physical iPhone run where one imported Windows executable reaches a first rendered frame, responds to guest input, initializes guest audio, and maintains `launchReady` plus `playabilityReady` without development-only overrides.

Until that lab run exists, Phase 2C remains active and the roadmap should not be marked complete.
