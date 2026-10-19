# App ownership and runtime integration

Iridium owns its app entry point, library records, screens, settings, artwork,
onboarding, Steam client, controls, save UI and project template. `App/` adopts
GPL-3.0-or-later Madeira code from revision
`279fd0f83170425db002fe25d6bd62f6355f497d`; this is a maintained fork, not a claim
that these implementations were written independently. `App/source-ownership.json`
records the original source units and build 43 source hashes. `App/Origin/`
preserves Madeira's license and converter exception; existing per-file notices
remain. `MadeiraFrontend/` and `RuntimeSupport/` remain first-party sources.
The on-disk `madeira-library.json`, game IDs, Wine paths and save locations are
unchanged. Names retained for that compatibility do not transfer model ownership
to the engine checkout.

## Boundaries

`App/Models/IridiumWindowsLibrary.swift` holds the persisted Windows game record.
Native environment application is in the `LibraryEntry` extension in
`App/Adapters/Madeira/IridiumMadeiraLaunchProfile.swift`. The retained Windows
session coordinator, display bridge and library service live beside it. They
continue to own the existing cloud preflight, JIT continuation, runtime leases,
worker, counters and graceful stop. This is an adapter of the existing lifecycle,
not a second runtime state machine.

`App/Services/IridiumLibraryServices.swift` defines the UI's launch, JIT, Steam,
control editing and save operations. Production adapters delegate to the existing
state owners. The unified library consumes launch/JIT/Steam services; controls
settings consume the editing service (including native process admission); saves
settings consume the save service. The simulator supplies unavailable launch
callbacks and cannot launch mock titles. UI observation uses Iridium-owned
ObservableObject stores directly. These are deliberately not wrapped in another
copy of the same published state.

Console engines continue through `IridiumRuntimeDriver`, console session and
`RuntimeBridge` C interfaces. SameBoy, PSP and phase 3 component receipts and
native ABI/export audits remain mandatory. Windows native functions cross the
retained C/Objective-C bridging header. The Windows coordinator still contains
engine-specific presentation and platform integration; it is maintained in the
adapter directory and must be tested when that native contract changes.

## Build inputs

`ci/iridium_app_sources.py` enumerates the owned source tree. Staging removes all
upstream Swift, copies the app's maintained sources/resources and uses the owned
project template under `AppProject/`. Source membership is generated from that
tree. The template has no obsolete main-target Swift references and no personal
development team. Native relative paths describe the documented out-of-tree
staging layout; no developer machine or DerivedData path is committed.
App metadata, entitlements and asset catalogs are also maintained here. Native
C/Objective-C, bridging headers, engine resources, libraries and build recipes
still come from their pinned engine checkouts and are validated separately.

`madeira-frontend.overlay()` is a compatibility reader for existing host tests:
it returns maintained shipping source by its old logical unit name. It performs
no text substitution. The historical `madeira_presentation*`, player, control and
JIT overlay modules remain as build 43 migration fixtures for existing behavioral
regression tests. Their original inputs are frozen under `ci/fixtures/madeira-build43/`, with
licenses and source hashes. They are not invoked by preparation, verification or
packaging and never read a future engine pin’s UI; they are not an upgrade requirement. New changes belong in maintained Swift/JS.

## Updating an engine

1. Inspect the candidate locally, without changing the pin. Run
   `python3 ci/check-engine-upgrade.py --madeira-source /path/to/candidate`.
   It compiles real native headers with the iOS SDK and compares functions,
   globals, callback typedefs and public record fields against the reviewed API
   contract in `ci/engine-integrations/`. It never reads upstream UI text. App preparation also runs this check automatically.
2. Review native integration obligations listed in the integration manifest.
   API compatibility alone does not prove runtime behavior or binary ABI safety.
3. Update the pin and provenance together only after review. Rebuild native
   components rather than resealing old receipts. Run focused compatibility,
   JIT lifecycle, input, cloud, saves and ownership tests, then the full source
   checks, actual app build and portrait/landscape simulator checks.
4. Test actual games on authorized hardware before claiming device compatibility.
   Generate corresponding source, check component/license/asset/package audits,
   and verify the replacement IPA before atomic delivery.

A compatible upstream UI redesign requires no source rewriting. A native API,
resource layout, build recipe or integration patch change can still require
adapter/build work; this is not a plug-and-play engine upgrade guarantee.

## First-game setup

Onboarding is maintained in `MadeiraFrontend/IridiumOnboarding.swift`. It opens
existing Files import, Steam sign-in/library, controls and JIT screens rather
than implementing parallel services. A successful import records its game ID and
runtime capability for guidance. PSP's optional JIT choice writes the existing
per-game setting. Windows controls keep their legacy layout fallback.

Setup preferences use the existing `iridium.setup` namespace. Revision 2 retains
raw step identifiers and exact skip/resume positions, including the former .NET
step. Completion queues one library action and consumes it after the owning modal
has dismissed; missing game records return to Files rather than selecting a stale
ID. Native game/launch/server admission remains authoritative. No library schema,
save path, JIT readiness flag or engine pin changes as part of this flow.
