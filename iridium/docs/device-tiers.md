# Legacy Device-Tier Metadata

Iridium no longer treats abstract device tiers as a user-visible launch gate.

The codebase still contains `DeviceTier` values in `packages/profiles`, `packages/runtime`, and runtime-bundle manifests, but they should be read as legacy tuning metadata and migration debt, not as product truth about whether a title can launch.

## Current policy

- Launch readiness must come from explicit host/runtime facts such as:
  - JIT readiness
  - bundled runtime validation
  - `launchReady`
  - `launchStatusSummary`
  - storage pressure
  - explicit whitelist rules when a title truly needs one
- The UI must never block or explain launch in terms of `tier1`, `tier2`, or `tier3`.
- New product-facing docs should not describe supported devices in tier language.

## Why this file still exists

The underlying types are still present in code because they are referenced by:

- compatibility presets in `packages/profiles`
- some runtime-policy defaults and environment overrides in `packages/runtime`
- runtime-bundle manifest metadata
- older tests and harness fixtures

That implementation residue is real, but it is not the contract we want users or contributors to design around.

## Migration direction

New work should move decisions away from abstract tiers and toward explicit capability checks:

- If a title needs a real hard block, report the concrete reason from the runtime or policy layer.
- If a title only needs softer tuning, keep it as an internal compatibility/profile default.
- If a feature requires hardware support, document the required capability directly rather than inventing another tier rule.

## What `packages/profiles` should own now

- Compatibility profile definitions.
- Broad-catalog title classification.
- Internal runtime-policy defaults and tuning hints.
- Explicit whitelist entries where they still exist.

If a future slice removes `DeviceTier` from code entirely, this file can be deleted. Until then, treat it as a deprecation note, not a roadmap endorsement.
