# Release policy

## Version and scope

Use Semantic Versioning: `MAJOR.MINOR.PATCH`, with optional prerelease labels
such as `0.2.0-beta.1`. Tags use a `v` prefix. Before 1.0, document incompatible
changes explicitly and use a minor version increase. After 1.0, incompatible
changes to the supported runtime SDK, library/save formats, configuration, or
other documented public contracts require a major version. Additive behavior
uses a minor version; compatible fixes use a patch. Never reuse a released tag
or replace a published artifact silently.

The first release uses tag `v0.1.0`, app version `0.1.0`, and description
`docs/releases/0.1.0.md`.

The maintainer chooses the release version. Do not infer it from the number of
commits. Set the app's marketing version to the numeric release core and record
the unique CI build number separately. Prerelease status belongs in the tag and
release notes. Verify actual bundle metadata, including helper extensions,
before publishing. No version is assigned by this policy change.

## One source for the description

Copy `docs/releases/TEMPLATE.md` to `docs/releases/VERSION.md`. Replace every
placeholder and retain all headings. Lead with the IPA download, requirements, and a short installation flow. Use
short player-facing changes and known issues. Keep source, license, checksum,
and build evidence inside the template's collapsed details section. Put notices
and build/relink instructions in one source-guide ZIP, with one checksum file
for the downloadable assets. Split large source archives only when required by
the hosting limit. Preserve the complete source and required notices; simplifying
the page must not remove them. Avoid internal audit history and unsupported
compatibility claims.

The reviewed file is the GitHub release description. Do not use automatic
GitHub-generated notes as the final description. Validate and render it with:

```sh
python3 ci/check-standards.py
python3 ci/check-standards.py --release VERSION
```

The second command writes the checked description to stdout. It does not create
a release. When publication is explicitly authorized, use the reviewed file as
`gh release create ... --notes-file docs/releases/VERSION.md`. Create a draft
first, inspect the actual assets and description, then publish deliberately.
Do not use a placeholder command as proof that publication happened.

## Release sequence

1. Select an exact source commit after review and green source checks. Review
   outstanding issues, `ci/binary-release-blockers.json` (build readiness), and
   `ci/binary-package-blockers.json` (final binary review); never clear entries
   just to make CI green. Record the evidence that resolves each entry.
2. Start the manual build only when requested. Retain its commit, run URL,
   dependency revisions, source archive, notices, and checksums. Fix failures
   through reviewed source changes, then choose another manual run.
3. Audit the actual IPA and corresponding source. Check every nested executable
   is unsigned, no signing/pairing material is present, and bundle versions match.
   Confirm the source archive includes local patches and required build inputs.
4. Perform the release's stated simulator/device tests. Do not claim untested
   games or input/audio paths work. If device checks are unavailable, label the
   release experimental and list that limitation clearly.
5. Complete the release description. Include installation and signing limits,
   JIT requirements, migration/save advice, test evidence, and known problems.
6. With publication authorization, tag the verified commit and make a draft.
   Attach the unsigned IPA, exact corresponding-source archive, checksums, and
   required notices. Check downloads and checksum verification before publishing.
7. If a serious regression appears, mark the release as affected and publish a
   new fix version. Preserve old source and checksums. Give data-safe recovery
   instructions; never advise deleting saves as a routine rollback.

Actions artifacts are temporary test outputs, not permanent release source
hosting. A published binary needs accessible matching source beside it. Retain
both together. No maintainer signing certificate is used at any stage.

## Enforcement and limits

CI validates release filenames, headings, placeholders, and evidence fields.
Reviewers verify the truth of the evidence, license coverage, migration safety,
and artifact correspondence. Automated text checks cannot establish those facts.
Repository branch protections and human approval remain separate controls.

References:
- https://semver.org/spec/v2.0.0.html
- https://keepachangelog.com/en/1.1.0/
- https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository

The final binary review gate runs after Xcode and before IPA packaging or upload.
App link maps are generated and retained for seven days even when that gate
blocks packaging. A missing or invalid final-review record blocks packaging.
This permits an audit build without treating it as an approved release.

The audit artifact also records each native binary's bundle-relative path, size,
SHA-256 digest and dynamic library references. It contains no executable payloads.
Compare static dependencies using the link maps; dynamic references alone cannot
establish static-library source coverage. Inventory failures block packaging.

## Source package and component records

Keep three decisions separate for each component: permission to distribute,
source/notice obligations, and engineering evidence. Use `UNRESOLVED` when the
available evidence does not establish a decision. Record Apple contractual
permission for the intended distribution route separately from component grants.
A System Library source exclusion does not itself grant redistribution rights.

Deliver one versioned `Iridium-corresponding-source.tar.gz` beside the IPA.
It contains the exact checkout (including submodule sources), dependency source
archives, patches, generated inputs or their generators, build and replacement
instructions, licenses, notices, and a component manifest. Keep the archive and
its checksum at a permanent versioned release URL for as long as required by
the distribution method; a seven-day Actions artifact is not that URL.
Do not include Apple SDKs, compiler object files, signing material or game data.
Document externally obtained toolchain prerequisites and applicable exclusions.

Use the accepted component manifest and static-archive mappings. Each major
component needs its license, source revision or archive, modifications, build
entry point, notice location, and bundle outputs. Existing detailed records may
remain as evidence; do not expand them into per-object requirements. The
accepted 2,423-file inventory has no unmapped files and the 24 static-archive
mappings are sufficient. A new dependency needs a license/source record, not a
new forensic audit of unchanged components.

Use release hashes to identify what was shipped and to check transfers.
Do not compare a modified rebuild to the release hash as a license test.
A complete buildable source package can provide LGPL replacement material;
a separate application object kit is needed only if the chosen compliance route
or missing buildable application source requires it. A marker test is optional.
See the replacement commands in [the build instructions](actions-ipa.md).

## Open-source audit scope

Use the completion rule in LICENSING.md. Device tests do not gate open-source
compliance completion. Apple compiler-runtime uncertainty is a residual licensing
risk; public unsigned-IPA contractual authorization is a separate acknowledged
risk outside this audit. Do not research those questions indefinitely or require
exact Apple object-source matching without affirmative evidence of a prohibition.
