# Manual unsigned IPA workflow

The workflow is available at **Actions → Build unsigned IPA → Run workflow**. Select the branch, then start the run. Its only trigger is `workflow_dispatch`: commits, pull requests, tags, and schedules cannot start an IPA build. The separate source privacy workflow still runs automatically.

**Current limitation:** this source snapshot does not yet have a complete clean-runner runtime preparation step. A manual run currently stops at `Check full-runtime build readiness`; it will not produce an IPA. Missing inputs include legacy host/userland staging, native libraries, Windows modules, the media/input binaries, and StikJIT. The StikJIT transitive source notice also remains unresolved. Adding a trigger does not solve those dependencies.

The Xcode and unsigned packaging steps are wired after that check, but have not been run. Do not upload local artifacts or signing files to bypass it. The remaining work below must be completed before the workflow is usable end to end.

No IPA workflow was dispatched while adding it. Static trigger checks and synthetic package rejection tests were run without compiling an app. Run them with `python3 -B -m unittest discover -s ci -p 'test_*.py'`.

The package step rejects certificates, provisioning profiles, private-key text, device identifiers, missing helper executables, and escaping symlinks. It strips existing vendor code signatures in a temporary staging copy and checks each native executable before creating the IPA. It never imports a keychain or accesses signing credentials.

## Runner and cost

GitHub documents free standard hosted runners for public repositories. The `xcode-27` standard preview image provides Xcode 27. Do not use `xcode-27-xlarge` or other paid larger runners. Verify the image at the time of implementation. Standard runners have finite memory, disk space, and job duration; the full Wine/FEX/media build must be measured before promising it fits.

Store source in Git without LFS. Use short-lived Actions artifacts for test IPAs, and GitHub Release assets for published IPAs and corresponding-source archives. Review artifact/cache storage limits; free runner time does not mean unlimited storage.

## Required preparation

1. Make the runtime, media SDK, ARM64EC modules, FEX, DXMT, and crypto-library stages build from pinned sources on a clean runner. Existing references to `/tmp/iridium-media-sdk` and manually staged libraries do not provide a reproducible dependency build.
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
