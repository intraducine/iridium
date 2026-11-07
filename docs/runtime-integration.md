# Runtime integration

Iridium owns the app entry, library, artwork, settings, setup, store UI, and
controls. Engines provide execution through native adapters. Source revisions
are recorded in [UPSTREAM-SOURCES.json](../UPSTREAM-SOURCES.json).

## Source layout

| Path | Responsibility |
| --- | --- |
| `iridium/apps/ios/App` | Maintained app models, services, and Madeira adapter |
| `iridium/apps/ios/MadeiraFrontend` | Shared library and player UI |
| `iridium/apps/ios/RuntimeBridge` | Engine C interfaces, input, audio, and lifecycle adapters |
| `iridium/apps/ios/AppProject` | App project, metadata, and entitlements |
| `vendor` | Pinned engine sources and dependencies |
| `ci` | Build, source collection, component receipts, and checks |

`App` includes Madeira-derived code from
`279fd0f83170425db002fe25d6bd62f6355f497d`. Its source-ownership manifest and
`App/Origin` retain import hashes, licenses, and the Converter Exception.
The build stages maintained sources through `ci/iridium_app_sources.py`;
upstream UI changes do not rewrite the app.

## Engine boundaries

The unified library retains Windows records and separate console records.
`IridiumRuntimeDriver` declares engine capabilities and lifecycle requirements.
Only one game may own the process. A retained Windows host accepts separate game
jobs, then returns admission after confirmed guest-thread cleanup. Uncertain
teardown retains ownership until restart.

Console engines use isolated binaries and checked C interfaces. Components have
separate pins, build outputs, resources, and receipts. Shared JIT handles provider
selection and launch admission; each engine validates its own executable memory.
Changing one engine need not change another, but its adapter and dependencies
must remain compatible. See [console engines](console-engines.md).

Windows keeps `madeira-library.json`, game IDs, Wine paths, and saves. Console
records use `Documents/IridiumRuntimes/library.json`. Managed Windows and console
games use `Documents/Games/<title> - <UUID>`. Journaled aliases retain old Windows
paths. Console saves stay isolated by runtime and storage owner, including shared
installed 3DS content. Corrupt libraries block writes. Removing an entry retains
files; store uninstall is a separate operation. Imports reject unsafe paths and
conflicting saves. See [storage and recovery](console-engines.md#import-and-storage).

Shared JIT prepares the Windows arena or console arena only when that launch
needs it. Each remains reusable until the app exits. The owned helper uses the
[checked transport](../iridium/apps/ios/JITSupport/README.md); older external
helpers retain the safe per-page fallback. Runtime pins and the version 1 memory
interface remain separate from this app service.

The shared launch presentation appears before native work and retains status and
live app memory use until readiness or failure. App UI remains on the main thread;
runtime work uses its adapter queues. This contract requires device timing and
rotation tests under native load. Source checks alone do not establish responsiveness.

## Engine updates

1. Inspect the candidate and its licenses. For Madeira, run
   `python3 ci/check-engine-upgrade.py --madeira-source /path/to/candidate`.
2. Review the native contract in `ci/engine-integrations`, build inputs, resources,
   and adaptation recipes. Update pins and provenance together.
3. Rebuild affected components and run focused tests plus the [source checks](../CONTRIBUTING.md#checks).
4. Build the app and test games on the target device before claiming compatibility.
   Update source collection and notices with any dependency change.

API checks do not establish binary or game compatibility. Version changes may
require adapter work; arbitrary prebuilt engines are not interchangeable.

## Retained development code

`iridium/packages/core`, `profiles`, and `runtime` retain the earlier store,
tuning, and runtime-bundle contracts. Device tiers are tuning metadata, not
user-visible compatibility guarantees. The [runtime SDK](../iridium-runtime-sdk/README.md)
and adjacent FEX/Wine bridges support that earlier path. They are separate from
the current native Madeira backend.

The frozen build-43 overlays in `ci/fixtures` support migration regression tests.
They do not generate shipping app sources. New app changes belong in the
maintained Swift and JavaScript files.
