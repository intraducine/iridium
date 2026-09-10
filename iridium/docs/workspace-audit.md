# Workspace Audit

Date: 2026-05-17

This audit covers Iridium-owned code across the local multi-repo workspace:

- `iridium`
- `iridium-runtime-sdk`
- `iridium-fex-ios/iridium/ios`
- `iridium-wine-ios/iridium/ios`

Upstream Wine and FEX internals are treated as dependency code. Refactors there should stay limited to the Iridium bridge layer unless a bridge contract requires a focused upstream patch.

## Current Findings

| Priority | Area | Finding | Action |
| --- | --- | --- | --- |
| P0 | Product validation | Phase 2C still lacks physical iPhone proof for first frame, input, and audio from a real imported Windows executable. | Keep roadmap/audit language explicit; do not mark Phase 2C complete until the device acceptance run passes. |
| P1 | Repo hygiene | `iridium-wine-ios/iridium/ios` tracked generated build products, including `build.log`, `build/bridge_tests`, and test-tool object files. | Remove those artifacts from Git and keep ignore coverage in place. |
| P1 | Runtime contracts | Runtime environment keys were duplicated across Swift app/runtime code and the native host. | Centralize shared keys in `RuntimeEnvironmentKey` and runtime SDK host-contract constants; migrate high-churn call sites first. |
| P2 | Large files | `AppViewModel.swift`, `RuntimeHost.swift`, `Services.swift`, and `runtime_host_core.cpp` carry multiple responsibilities per file. | Split by behavior only after characterization tests or direct call-site coverage protects the moved code. |
| P2 | Validation tooling | This container lacks Swift, CMake, Xcode, XcodeGen, and codedb, so full validation must run on the macOS/Xcode development machine. | Use `scripts/audit-workspace.sh` for repeatable local checks, then run repo-specific build/test commands where tools are installed. |

## Refactor Guardrails

- Preserve public Swift package products, C headers, runtime bundle layout, and bridge ABI.
- Avoid broad upstream Wine/FEX reformatting or structural churn.
- Prefer file splits, constants, small adapters, and focused tests over architecture redesign.
- Keep physical-device playability as a product gate, not a proxy inferred from host-only tests.

## Runtime Contract Ownership

- Swift app/runtime code should use `RuntimeEnvironmentKey` for shared `IRIDIUM_*` launch, bundle, Wine iOS bridge, and telemetry keys.
- Native host code should use constants from `iridium_runtime_host_contract.hpp` for host-owned key names.
- New environment keys should be added to the owning contract before use at call sites or in tests.

## Validation Checklist

Run these from a macOS/Xcode environment with the sibling repos present:

```bash
cd iridium
./scripts/audit-workspace.sh
swift test
./scripts/doctor.sh --app-build
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

cd ../iridium-runtime-sdk
swift test
cmake -S . -B build
cmake --build build

cd ../iridium-fex-ios
./iridium/ios/tests/build_embedded_translator_smoke.sh

cd ../iridium-wine-ios
./iridium/ios/tests/package_tests.sh
```

Physical-device validation must still prove:

- `launchReady = true`
- `playabilityReady = true`
- presentation, input, and audio readiness are all `ready`
- no development-only override is required
- one lightweight Windows title reaches a rendered frame with working input and initialized audio
