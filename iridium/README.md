# Iridium

Iridium is an iPhone and iPad Windows-game runtime project. The main app repo owns the Swift package graph, the iOS shell, durable store/runtime contracts, bundled-runtime provisioning, and the product-facing import/JIT/launch lifecycle. Runtime code lives in the adjacent runtime repositories and the Madeira integration.

## Workspace structure

```text
iridium/
  apps/
    ios/                  SwiftUI shell and Xcode project
  packages/
    core/                 Durable store, persistence, lifecycle truth
    profiles/             Compatibility presets and legacy tuning metadata
    runtime/              Runtime provisioning, host, launch, validation
  docs/
    architecture.md
    device-tiers.md
    implementation-context.md
    manual-validation-runbook.md
    roadmap.md
    setup.md
  scripts/
    bootstrap.sh
    generate-project.sh

../iridium-runtime-sdk/    Native runtime host SDK and runtime-bundle assembly
../iridium-fex-ios/        Source-owned FEX fork and iOS embedding bridge
../iridium-wine-ios/       Source-owned Wine fork and iOS userland bridge
```

## Documentation

- [Architecture](docs/architecture.md)
- [Implementation context](docs/implementation-context.md)
- [Manual validation runbook](docs/manual-validation-runbook.md)
- [Legacy device-tier metadata](docs/device-tiers.md)
- [Setup](docs/setup.md)
- [Roadmap](docs/roadmap.md)

## Current status

- `Package.swift` exposes `IridiumCore`, `IridiumRuntime`, `IridiumProfiles`, `IridiumBridgeHost`, and `IridiumAcceptanceHarness`.
- Add a Windows game folder, select its cover, and choose Play.
- `packages/core` owns durable library, prefix, launch-history, verification, activity, and pending-launch truth.
- `packages/runtime` owns bundled-runtime provisioning, runtime validation, host capability probing, prefix bootstrap, and the bundled-device backend contract.
- `apps/ios` owns the activation-first SwiftUI product experience, including LiveContainer repair, folder import, contextual launch support, per-game configuration, and queued launch resume behavior. See [Product experience](docs/product-experience.md).
- The iOS app uses a bundled runtime.
- Runtime health and launch readiness report the requirements that block a launch.
- The Madeira integration runs Windows games through Wine/FEX. Compatibility and performance require testing for each game and device.

## Working principles

- Keep `apps/ios` thin. Product UI should compose package APIs, not absorb runtime rules.
- Keep durable truth in `packages/core`.
- Keep compatibility presets and legacy tuning metadata in `packages/profiles`.
- Keep provisioning, host, launch, and runtime validation behavior in `packages/runtime`.
- Keep engine-port work in `../iridium-runtime-sdk`, `../iridium-fex-ios`, and `../iridium-wine-ios`.
- Explain launch requirements through device capabilities and runtime checks.
- Evolve docs alongside implementation so the roadmap stays falsifiable.

## Building

Use the monorepo [build guide](../docs/actions-ipa.md) for the current Madeira
integration, dependency preparation, and unsigned Xcode build. The workflow
contains the commands for each build stage.
