# Releases

Builds and publication require explicit maintainer approval. Keep builds manual
and use the exact reviewed commit with passing source checks.

## Version and notes

Use Semantic Versioning and `vMAJOR.MINOR.PATCH` tags. The maintainer chooses the
version. Before 1.0, describe incompatible changes and increase the minor version.
After 1.0, breaking public contracts require a major version. Keep the numeric
app version and unique CI build number consistent across the app and extensions.
Never reuse a released tag or silently replace its assets.

The current development version is **0.3.0**, with
[unpublished review notes](releases/0.3.0.md). Its app version is independent of
the pinned Madeira 0.2.0 runtime. A version increase and a review build do not
authorize a tag, release, or publication.

Copy [TEMPLATE.md](releases/TEMPLATE.md) to `releases/VERSION.md`. Keep its headings
and evidence fields. Lead with installation and user-visible changes. Keep source
and build details collapsed. Validate with:

```sh
python3 ci/check-standards.py
python3 ci/check-standards.py --release VERSION
```

Use the reviewed file as the release body. Historical notes describe their
original artifacts; do not apply current compatibility claims to old releases.
For an unpublished draft, label earlier source/run fields as baseline evidence.
Before publication, replace them with the exact verified release source and run,
plus matching artifact versions and checksums. A linked PR can track pending
review builds, but is not a release artifact or a compatibility result.

## Publish

1. Review `ci/binary-release-blockers.json` and `ci/binary-package-blockers.json`.
   Resolve entries with evidence; do not remove them to bypass checks.
2. Start a release-mode build: `python3 ci/dispatch-build.py --release`.
   Default test builds omit source and release-audit uploads and cannot be
   promoted without the missing matching materials and checks.
3. Inspect the actual IPA, source archive, component manifest, link maps,
   checksums, bundle versions, and signature audit. Check privacy and licenses.
4. Test the stated games and device paths. Record untested items and migration
   or save risks. Builds alone do not establish device compatibility.
5. Tag the verified commit and create a draft with the reviewed notes. Attach
   the IPA, matching source, source guide with notices/relink instructions, and
   checksums. Split source archives only for hosting limits.
6. Verify downloads and checksums, then publish with authorization.

Keep matching source and notices at permanent versioned release URLs. Preserve
old source, checksums, and data-safe recovery steps when issuing a fix release.

## AltStore Classic

After publishing a stable release, use its checked IPA to update the Stable
source. Review the JSON change and merge it into `main`.

```sh
python3 ci/update-altstore-source.py v0.3.0 /path/to/Iridium-unsigned.ipa
```

For Nightly, select `main` and enable `nightly` in the manual IPA workflow. The
workflow collects and audits matching source, then publishes the IPA and source
as a versioned GitHub prerelease after the build passes. It splits the source
archive into assets under 2 GiB and verifies every uploaded checksum before
updating the separate `altstore-nightly` branch. Older releases stay available.

```sh
python3 ci/dispatch-build.py --nightly
```

The Stable updater checks the IPA against its published size and checksum.
The Nightly feed points to a run-specific release and its matching source.
Nightly prereleases do not replace GitHub's latest stable release.

## Source and signing

The source package must include the exact checkout and dependencies, patches,
generators, build/relink instructions, notices, and `COMPONENT-MANIFEST.json`.
Record each component's license, revision, modifications, build entry, and bundle
outputs. Use the final binary inventory and static link maps; dynamic imports
alone do not identify static dependencies. Do not add per-object requirements
without a license reason.

Exclude Apple SDKs, game data, private logs, and signing or pairing material.
A complete buildable source package can supply LGPL replacement material;
modified rebuilds do not need to match release hashes. See [replacement commands](actions-ipa.md).

Packaging allows only the main app's anonymous increased-memory-limit carrier;
helpers remain unsigned. Check its sole entitlement, empty CMS payload, absent
team identity, and resource seal. Recipients must sign the app and extensions.
The carrier grants no provisioning rights.

Keep distribution permission, source obligations, and runtime evidence separate.
Unresolved component decisions remain `UNRESOLVED`. Apple compiler-runtime
coverage and unsigned-IPA contractual permission remain separate risks described
in [LICENSING.md](../LICENSING.md); device tests do not resolve them.
