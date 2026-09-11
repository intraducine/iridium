# Contributing to Iridium

This is the shared policy for code, reviews, documentation, and releases. It
applies to human and automated contributions. Component instructions add local
build and style rules. Third-party licenses and contribution restrictions still
apply; this policy does not replace them. Do not reformat upstream forks to
match Iridium.

## Change process

1. Describe the problem, intended behavior, and affected component before editing.
2. Inspect callers, existing helpers, tests, and working-tree changes. Preserve
   unrelated edits. Fix the shared cause rather than only the reported symptom.
3. Use a short-lived branch and one focused pull request. Keep refactors separate
   from behavior changes unless the refactor is required to fix the problem.
4. Test the changed behavior, document evidence and limits, and use the PR template.
5. Resolve review comments and checks before merging. Prefer squash merges with
   a clear imperative title. Do not require personal names in commit messages;
   use a GitHub noreply address if desired. Do not invent contributor identities.

Use titles such as `Fix controller reconnect handling`, not `Updates`. A strict
commit-prefix taxonomy is not required. Explain decisions in the PR rather than
writing a history of abandoned attempts. For a change to runtime architecture,
save formats, dependency licensing, or trust boundaries, record the decision,
alternatives, migration, and rollback in `docs/decisions/` before merging.

Third-party directories may require sign-off or reject AI-generated changes.
Read their contribution rules before editing or proposing an upstream change.
Do not promise that an Iridium change will be accepted upstream.

## Implementation

- Reuse existing code, standard libraries, and native platform controls first.
  Add a dependency only with a reason, source revision, license review, and owner.
- Keep UI, library state, runtime adapters, and platform integration separate.
  UI reads shared launch state; it must not maintain a competing readiness state.
- Follow surrounding Swift, C, C++, Python, and shell style. Use existing
  formatter settings. Do not add a global formatter over vendor code.
- Keep UI work on the UI thread. Keep blocking I/O and runtime operations off it.
  Give operations cancellation, bounded waits, and useful failures. Shutdown must
  return control to the UI even if runtime cleanup fails.
- Validate imported paths, archive members, executable inputs, and network data.
  Never interpolate untrusted input into shell commands. Do not swallow failures
  or claim success before the operation completes.
- Save and prefix changes need compatibility checks and recovery. Never erase
  user data as a default repair. Removing a library entry does not delete files.
- Keep logs useful: phase, outcome, duration, and stable error code where useful.
  Redact paths, identifiers, tokens, and pairing data before export. Do not log
  secrets, fabricate progress, or treat a player screen as proof of rendering.
- Preserve the Apple-style interface. Check safe areas, Dynamic Type, VoiceOver,
  contrast, Reduce Motion, and portrait/landscape behavior. Every action must be
  reachable with touch, keyboard, and controller where that input is supported.
  Focus, back/escape, modal dismissal, and repeated menu opening need real checks.

## Validation and evidence

Run the source checks for every change:

```sh
python3 check-public-source.py
python3 ci/check-standards.py
python3 -B -m unittest discover -s ci -p 'test_*.py'
git diff --check
```

Add a small regression test for changed nontrivial logic. Use the component's
existing tests; do not create a parallel framework. Reversible copy-only changes
need review, not a test that repeats their text. Changes to tests or checks must
not quietly weaken the rule they enforce.

Report these evidence levels separately:

| Evidence | What it establishes |
| --- | --- |
| Static/source checks | The checked source properties only |
| Build and package checks | Compilation, layout, and signature state |
| Simulator interaction | The tested UI behavior in that simulator |
| Physical-device run | Only the tested device, OS, game, and input paths |

Runtime verification records must name the source commit, build, device model,
OS, game/version, input method, steps, observed result, and limits. Do not publish
serial numbers, UDIDs, private paths, game data, or raw personal logs. Verify
frames, interaction, audio, save persistence, and shutdown separately. Mark
untested items as untested. A passed build never means universal compatibility.

## Dependencies, privacy, and security

Pin source revisions or digests, preserve upstream notices, and record changes in
`CHANGES-FROM-UPSTREAM.md`. Update source collection with every linked dependency
change. Review the actual license expression and transitive inputs; a root
license or source URL alone is insufficient. Never bypass release audit blockers
by uploading local binaries. Do not claim formal compliance or certification
from a checklist.

Never commit or upload maintainer certificates, keys, profiles, pairing records,
private device logs, game files, commercial artwork, or Apple SDKs. No signing
credentials belong in Actions secrets. Review filenames, metadata, logs, and
archives, not only source strings. Rotate an exposed secret; deleting it from
the latest commit is not enough.

For security reports, use GitHub private vulnerability reporting if enabled.
If it is unavailable, open a minimal issue asking for a private reporting channel
without exploit details or personal data. No response-time guarantee is offered.
Do not test systems or accounts without permission.

## CI and repository controls

Source checks may run on pushes and pull requests. Compilation and release work
must be manual (`workflow_dispatch`). Do not add tag, push, schedule, or PR build
triggers. Pin third-party Actions to full commits. Use read-only permissions by
default; never run untrusted PR code with secrets or `pull_request_target`.

The maintainer should protect `main` against deletion and force pushes, require
pull requests, resolved conversations, and the `privacy` source-check job. Require
an independent approval when another maintainer is available. Do not configure
an impossible self-approval rule for a sole maintainer. Any emergency bypass must
be documented and followed by review. GitHub settings enforce these protections;
this document alone does not enable them.

## Releases

Follow [the release policy](docs/releasing.md). No build, tag, draft release, or
publication occurs merely because a PR merges. The maintainer chooses each run.
