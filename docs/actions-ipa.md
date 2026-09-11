# Manual unsigned IPA workflow

The workflow is available at **Actions → Build unsigned IPA → Run workflow**. Select the branch, then start the run. Its only trigger is `workflow_dispatch`: commits, pull requests, tags, and schedules cannot start an IPA build. The separate source privacy workflow still runs automatically.

**Status:** the remaining runtime build recipes are now scripted. They have not been compiled on a clean runner. IPA output remains blocked by the explicit source/license audit items in `ci/binary-release-blockers.json`. Do not start a full run expecting an installable package yet.

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
