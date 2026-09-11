# Manual unsigned IPA workflow

The workflow is available at **Actions → Build unsigned IPA → Run workflow**. Select the branch, then start the run. Its only trigger is `workflow_dispatch`: commits, pull requests, tags, and schedules cannot start an IPA build. The separate source privacy workflow still runs automatically.

**Status:** the remaining runtime build recipes are now scripted. They have not been compiled on a clean runner. The StikJIT script provenance is now documented. IPA output remains blocked by the remaining dependency/source audit items in `ci/binary-release-blockers.json`. Do not start a full run expecting an installable package yet.

The manual workflow has two stages:

- Linux builds the legacy Wine userland. It identifies copied Debian libraries, downloads their exact source-package versions, and transfers the userland together with source and copyright notices. Unknown package ownership or unavailable source fails the job.
- Apple Silicon macOS builds the native libraries, Wine Windows modules for both architectures, ARM64EC FEX, DXMT, a fresh temporary prefix, ANGLE frameworks, source-built GStreamer, and StikJIT with source-built idevice. It then packages the legacy runtime. The source/license gate runs before the application build and IPA upload.

`ci/runtime-inputs.json` locks archive URLs and SHA-256 values. FEX git dependencies use committed gitlinks. ANGLE and depot_tools use exact commits in `ci/prepare-graphics.sh`; ANGLE's DEPS selects its dependencies. The original graphics binary reported ANGLE revision `6024e9c05548`; building that revision does not establish that it includes every modification used by the old binary.

CI does not link the opaque idevice archive bundled in StikJIT. It removes that fetched archive and rebuilds idevice revision `7a1cca397a79589e177de163d888ba761a137ce5` with Rust 1.98.1 and locked Cargo dependencies. This replacement needs compile and device validation. CI also uses Cerbero 1.28.6 to build the iPhone GStreamer slice from source. The optional older prebuilt-SDK helper is not used by this workflow.

The scripts expect a fresh checkout, Python 3.12 or newer, and Xcode 27. Compiler parallelism defaults to two. Downloads and generated files stay in the checkout. Prefix preparation only sanitizes a newly marked temporary prefix; it never edits user saves. Homebrew tools and the Debian image are not fully version-locked. These recipes do not establish bit-for-bit reproducibility.

Inspect native inputs without downloads or compilation:

```sh
python3 ci/fetch-runtime-inputs.py --plan
bash ci/prepare-native-runtime.sh --plan
python3 -B -m unittest discover -s ci -p 'test_*.py'
```

Static checks and synthetic tests cover download rejection, prefix sanitization, PE architecture checks, unknown Debian library ownership, manual-only triggers, and unsigned-package rejection. They do not prove that the runtime compiles or works on an iPhone. No IPA workflow was dispatched for this change.

The package step rejects certificates, provisioning profiles, private-key text, device identifiers, missing helper executables, and escaping symlinks. It removes vendor signatures only in a staging copy and verifies native files before producing an IPA. It never imports a keychain or accesses signing credentials.

## Runner and cost

GitHub documents free standard hosted runners for public repositories. The `xcode-27` standard preview image provides Xcode 27. Do not use `xcode-27-xlarge` or other paid larger runners. Verify the image at the time of implementation. Standard runners have finite memory, disk space, and job duration; the full Wine/FEX/media build must be measured before promising it fits.

Store source in Git without LFS. Use short-lived Actions artifacts for test IPAs, and GitHub Release assets for published IPAs and corresponding-source archives. Review artifact/cache storage limits; free runner time does not mean unlimited storage.

## Required preparation

1. Make the runtime, media SDK, ARM64EC modules, FEX, DXMT, and crypto-library stages build from pinned sources on a clean runner. The stages are scripted but need clean-runner validation.
2. Retain local modifications and complete source/license records for every dependency. Resolve the StikJIT transitive-source note before distributing its binary.
3. Run source checks on pull requests with read-only permissions and no secrets. Build artifacts only from reviewed code. Do not use pull_request_target to execute pull-request code.
4. Run Xcode with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=`. Do not pass `-allowProvisioningUpdates`, import a keychain, or use Apple account credentials.
5. Package `Payload/Iridium.app` and all required unsigned nested bundles into an IPA. Remove pre-existing vendor signatures and provisioning profiles from the staging copy, and verify every Mach-O executable, framework, and extension before upload. Keep source entitlements for users' signing tools.
6. Audit the staged IPA for personal paths and metadata. Release it with checksums, exact corresponding source, build instructions, license notices, and signing instructions.

An unsigned IPA is not directly installable on a stock iPhone. Users must sign the app and its helper extensions with a suitable sideloading tool. JIT and entitlement support must be verified independently. CI cannot prove physical-device gameplay.

Never upload maintainer signing certificates, private keys, provisioning profiles, pairing records, Apple credentials, or private device logs to Actions, including as secrets. This project publishes unsigned artifacts only.

Sources:
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://github.com/actions/runner-images/issues/14404
- https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github

## Matching-source collection

The manual workflow now collects source before its publication gate. It captures
Iridium's exact Git revision, initialized gitlinks and their changes, verified
native source archives, ANGLE Git dependencies, StikJIT without its opaque FFI
archive, and idevice with vendored Cargo dependencies. Cerbero's own
`bundle-source gstreamer-1.0 --offline` includes its recipes and dependency sources.
The Linux source packages join these in `Iridium-corresponding-source.tar.gz`,
with `SOURCE-SHA256SUMS`, in the same output directory as the future IPA.

This collection is not yet a completed correspondence audit. Compiler runtime
sources, non-Git ANGLE inputs, resolved codec/crate license terms, and any
missing generated inputs must be checked against an actual build. The existing
publication gate stays closed. No source archive or IPA was built or uploaded
while adding this collector; only synthetic source-archive tests ran.

A later manual run may supply `linux_runtime_run_id` to reuse a completed Linux
artifact. CI requires a successful Linux producer job from this repository's
manual workflow on main or the current branch, the recorded source commit, unchanged Wine and
Linux preparation/source-collection inputs, and matching archive checksums.
This avoids recompiling unchanged Linux code for macOS-only fixes; it does not
claim bit-for-bit reproducibility. Expired artifacts require a fresh build.
The source-audit artifact is retained before the IPA publication gate, so the
matching source can be reviewed even when that gate blocks the binary.


## Compiler checks before media compilation

After fetching Cerbero, run `bash ci/prepare-media-sdk.sh --preflight` with
Xcode 27 selected. This does not bootstrap or compile the full SDK. It tests
Cerbero's resolved Mac and iPhone C++ compiler/linker settings, verifies the
ARM64 target, and checks the gperf recipe patch. Media libraries inherit the
application's explicit iOS minimum; host tools use the runner's macOS version.
The normal media command runs the same checks before bootstrap.

See [the build preflight review](build-preflight-2026-09-11.md) for measured
results and the remaining full-build checks. Compiler probes cannot guarantee
that every dependency compiles or that the final app links.


## Reusing verified build assets

Manual builds default to `reuse_assets=true`. A short planning job searches the
latest 30 manual runs for matching, retained media and Linux producer artifacts.
The whole earlier workflow need not have succeeded, but the actual producer job
must have succeeded and its artifact must still exist. Both stages may come from main
or the branch being built. Other branches and forks are rejected.

Reuse compares Git object IDs for stage inputs and the producer workflow job,
including runner, commands, action revisions, and inherited environment/defaults.
Only scheduling conditions are excluded. Changes to UI code do not invalidate
media. Recipe, pinned dependency, patch, compiler-check, app deployment config,
or producer-command changes do. Runner labels and install commands are compared;
floating hosted-image and Homebrew updates are not bit-for-bit toolchain pins.
Turn reuse off when a fresh compiler/image build is needed.

The existing Linux run override and new `media_run_id` override are verified by
the same selection rules. Invalid explicit overrides stop the run; automatic
misses trigger fresh builds. API failures stop planning rather than accepting
unverified output. Expired artifacts also require a new producer build.

The consumer downloads both binary and corresponding source, rechecks producer
provenance, and checks archive hashes before unpacking. Media manifests must
cover exactly the SDK and source archive. The original source revision stays
with the artifact; reuse does not relabel it as newly compiled source.

The macOS job also selects a prepared runtime after installing its build tools.
This package contains native Wine/FEX, Windows modules, the clean prefix, media
wrappers, controller modules, ANGLE, StikJIT/idevice, and the legacy runtime host
and bundle. Final app compilation and the source/license gate still run.

Native reuse compares its source trees and preparation scripts, the complete
build job, Xcode/Swift/iPhone SDK versions, macOS build, architecture, installed
Homebrew versions, and the exact restored media SDK and Linux archive hashes.
App-only Swift UI edits can reuse the package. Changes to dependency source,
project settings, recipes, or any of these toolchain inputs require a new build.
The broad source checks deliberately favor an extra build over stale output.

The first build must finish all dependency stages and upload their package.
Later manual runs find it automatically with `reuse_assets=true`; no run number
is needed. Native artifacts are retained for seven days and searched within the
latest 30 manual runs on main or the current branch. Only a successful
`Retain prepared runtime and source` step qualifies. A later app build failure
or license-gate failure does not discard that completed dependency work.
Reusing runs do not upload duplicate native packages.

Transfers include only final resources, link archives, needed headers, and
corresponding source, not compiler working directories or Apple SDKs. Restore
checks provenance, toolchain, archive checksum, member paths, and existing files
before copying. It rejects links and unexpected paths. The final source package
keeps `native-producer-iridium.tar.gz` and `native-producer-revisions.json` beside
the current app source. The restored runtime bundle retains its producer version.

Set `reuse_assets=false` and leave explicit media/Linux overrides empty to build
all dependencies fresh. Tool setup, downloads, verification, source packaging,
and app compilation still take time. No 30-second CI target is promised.

Local transfer, rejection, and workflow tests cover this path. A cold GitHub run
and a subsequent reuse run still need to validate the real native artifacts and
measure the time saved. The source/license publication gate remains unchanged.
