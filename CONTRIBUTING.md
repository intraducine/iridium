# Contributing

Use a focused branch and pull request. Describe the problem, change, validation,
and recovery. Read instructions and license notices in each affected component.
Preserve unrelated work and uninitialized submodules.

## Changes

- Inspect callers and existing helpers. Fix shared causes and keep unrelated refactors separate.
- Follow the component's style. Do not reformat upstream code.
- Keep UI work on the main thread and blocking work off it. Bound waits and handle cancellation.
- Validate paths, archives, executable inputs, and network data. Do not hide failures.
- Preserve games, saves, prefixes, and existing settings. Document migrations and rollback.
- Check touch, keyboard, controller, safe areas, Dynamic Type, VoiceOver, contrast, and reduced motion where affected.
- Pin dependencies, retain notices, update source collection, and record adaptations in [CHANGES-FROM-UPSTREAM.md](CHANGES-FROM-UPSTREAM.md).
- Keep temporary reports and build logs outside commits.

## Checks

Use Xcode 27 and initialize the test sources. Run from the repository root:

```sh
git submodule update --init --depth 1 vendor/Madeira vendor/SameBoy vendor/PPSSPP vendor/Dolphin vendor/Play vendor/Flycast
git -C vendor/Madeira submodule update --init --depth 1 wine FEX dxmt
git -C vendor/Play submodule update --init --depth 1 deps/CodeGen deps/Framework
python3 check-public-source.py
python3 ci/check-standards.py
python3 -B -m unittest discover -s ci -p 'test_*.py'
git diff --check
```

Add a focused regression test for changed logic. Do not weaken checks to pass CI.
Source checks use pinned Xcode 27. A manual build can reuse their result only
for the same commit and host environment. Compilation and release builds remain
manual.

Report source, build, simulator, and device results separately. For device tests,
record the commit, build, model, OS, game/version, input, steps, and limits.
Verify rendering, input, audio, saves, and shutdown separately.

## Privacy

Never commit or upload keys, certificates, profiles, pairing records, private
logs, device identifiers, games, commercial artwork, or Apple SDKs. Redact logs
before sharing. Rotate exposed secrets.

Use GitHub private vulnerability reporting for security issues. If unavailable,
request a private contact without publishing exploit details.

## Review and release

Resolve comments and checks before merging. Prefer squash merges. Protect main
from deletion and force pushes; require PRs, resolved conversations, and the
`privacy` check. Require an independent approval when another maintainer is
available. Document any emergency bypass.

Keep Actions pinned to full commits with read-only permissions. Do not use
`pull_request_target`, upload signing credentials, or trigger compilation on
pushes, tags, or PRs. A merge does not authorize a build or publication.
Follow [the release process](docs/releasing.md).
