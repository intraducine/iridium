# Release policy

## Version and scope

Use Semantic Versioning: `MAJOR.MINOR.PATCH`, with optional prerelease labels
such as `0.2.0-beta.1`. Tags use a `v` prefix. Before 1.0, document incompatible
changes explicitly and use a minor version increase. After 1.0, incompatible
changes to the supported runtime SDK, library/save formats, configuration, or
other documented public contracts require a major version. Additive behavior
uses a minor version; compatible fixes use a patch. Never reuse a released tag
or replace a published artifact silently.

The first release has the maintainer-approved tag `v0.1`, mapped to app
version `0.1.0` and description `docs/releases/0.1.0.md`. This is a specific
tag spelling exception; later releases use the full three-part tag.

The maintainer chooses the release version. Do not infer it from the number of
commits. Set the app's marketing version to the numeric release core and record
the unique CI build number separately. Prerelease status belongs in the tag and
release notes. Verify actual bundle metadata, including helper extensions,
before publishing. No version is assigned by this policy change.

## One source for the description

Copy `docs/releases/TEMPLATE.md` to `docs/releases/VERSION.md`. Replace every
placeholder and retain all headings. Write for users. State concrete changes,
not commit titles or unsupported performance claims. Group changes using the
Keep a Changelog categories: Added, Changed, Deprecated, Removed, Fixed,
Security. Omit empty categories. State when there are no user-visible changes.

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
   outstanding issues and `ci/binary-release-blockers.json`; never clear entries
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
