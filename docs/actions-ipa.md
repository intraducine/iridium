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


## Reuse completed compiler stages

Successful runtime compiler stages are saved separately: native libraries,
Wine, Windows modules (FEX and DXMT), ANGLE graphics, and StikJIT/idevice.
Wine is uploaded before Windows staging. Windows modules are uploaded before
prefix creation. A later packaging failure does not discard these outputs.

Each artifact expires after seven days. A run that reuses one does not upload
another copy or extend its lifetime. Missing or expired artifacts trigger a
fresh component build. The previous combined native-runtime package is no
longer uploaded, avoiding another copy of the same compiled libraries.
Media and Linux artifacts also use seven-day retention.

Reuse requires a successful upload step from a manual build in this repository
on main or the current branch. Source inputs and the compiler recipe must match.
The tool fingerprint includes Xcode, SDK, Swift, host OS, architecture, installed
Homebrew versions, media/Linux input digests, and the workspace location.
Archives carry the producer revision and a SHA-256 checksum. Restoration checks
both before extraction, limits paths to the component's output roots, and
preserves executable permissions. Object files are omitted. Configured Wine
outputs and import libraries remain because DXMT and prefix creation need them.

A packaging-only edit does not invalidate Wine compilation. Changes to shared
build tools or dependency sources can invalidate more than one component.
Pinned downloads and source checkouts are prepared on every run without
compiling them. Source collection and the release-license gate remain required.
The application is still built and audited by the final stages.

Set `reuse_assets=false` and leave explicit media/Linux overrides empty for a
fresh build. Local tests cover completed-stage reuse after a later failure,
expired/missing selection, checksum failure, executable permissions, and
packaging edits versus compiler edits. Real CI restoration is still pending.
