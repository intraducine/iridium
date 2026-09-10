# Iridium

Iridium is an iPhone and iPad Windows-game runtime project. The main app repo owns the Swift package graph, the iOS shell, durable store/runtime contracts, bundled-runtime provisioning, and the product-facing import/JIT/launch lifecycle. The actual engine-port work now spans sibling runtime repos beside this one.

The docs in this repo should describe the real workspace and the real blocker. If the runtime architecture changes, update the docs in the same slice.

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
- [Workspace audit](docs/workspace-audit.md)
- [Legacy device-tier metadata](docs/device-tiers.md)
- [Setup](docs/setup.md)
- [Roadmap](docs/roadmap.md)

## Current status

- `Package.swift` exposes `IridiumCore`, `IridiumRuntime`, `IridiumProfiles`, `IridiumBridgeHost`, and `IridiumAcceptanceHarness`.
- The shipped app surface is empty-first-launch and manual-import-first.
- `packages/core` owns durable library, prefix, launch-history, verification, activity, and pending-launch truth.
- `packages/runtime` owns bundled-runtime provisioning, runtime validation, host capability probing, prefix bootstrap, and the bundled-device backend contract.
- `apps/ios` owns the activation-first SwiftUI product experience, including LiveContainer repair, folder import, contextual launch support, per-game configuration, and queued launch resume behavior. See [Product experience](docs/product-experience.md).
- The bundled-device runtime path is the product path.
- Runtime health and launch readiness now surface concrete host/runtime blockers instead of generic placeholder success.
- A true playable iPhone Wine/FEX engine is not landed yet; the active engine work lives in the sibling runtime repos.

## Working principles

- Keep `apps/ios` thin. Product UI should compose package APIs, not absorb runtime rules.
- Keep durable truth in `packages/core`.
- Keep compatibility presets and legacy tuning metadata in `packages/profiles`.
- Keep provisioning, host, launch, and runtime validation behavior in `packages/runtime`.
- Keep engine-port work in `../iridium-runtime-sdk`, `../iridium-fex-ios`, and `../iridium-wine-ios`.
- Do not reintroduce user-visible launch gating based on abstract device tiers.
- Evolve docs alongside implementation so the roadmap stays falsifiable.

## Local workflow

1. Accept the local Xcode license with `sudo xcodebuild -license accept`.
2. Install `xcodegen` if it is not present.
3. Clone the sibling runtime repos next to this repo.
4. Refresh the canonical embedded FEX artifacts for `host`, `device`, and `simulator` with `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform <platform>`.
5. Build the canonical runtime bundle in `../iridium-runtime-sdk/build/iridium-runtime-base`.
6. Set `IRIDIUM_AMETHYST_ROOT` or clone `Amethyst-iOS` next to this workspace for the iOS OpenGL frameworks.
7. Run `./scripts/doctor.sh --bootstrap`, then `./scripts/bootstrap.sh`.
8. Before building the app target, run `./scripts/doctor.sh --app-build`.
9. If bootstrap fails during package resolution, verify the sibling repos exist at the expected relative paths and rerun the canonical embedded FEX build commands.
10. Open `apps/ios/Iridium.xcodeproj` in Xcode.
11. Use the docs plus the sibling runtime repos as the shared source of truth for engine work.
