# Manual unsigned IPA workflow

The workflow is available at **Actions → Build unsigned IPA → Run workflow**. Select the branch, then start the run. Its only trigger is `workflow_dispatch`: commits, pull requests, tags, and schedules cannot start an IPA build. The separate source privacy workflow still runs automatically.

**Current limitation:** native preparation is now scripted, but full IPA preparation is not complete. A manual run first builds the native libraries and media/input components, then checks the remaining inputs. It still cannot produce an IPA from a clean checkout. Windows runtime modules, the clean prefix, the legacy Linux userland/host bundle, and the legacy graphics frameworks remain missing. StikJIT transitive source records remain unresolved.

`ci/prepare-native-runtime.sh` uses this repository's existing build helpers. It downloads SHA-256-locked GMP, Nettle, GnuTLS, FreeType, LLVM 15, and the llvm-mingw compiler. Git dependencies use the committed gitlink revisions, without binary test corpora. It builds the LLVM host table generator, iOS LLVM libraries, Madeira FEX and Wine native archives, DXMT Metal shader headers and combined archive, legacy FEX/Wine native archives, and media/controller libraries. The GStreamer SDK remains an official digest-checked **prebuilt** input; its component source/notice inventory is still needed before binary distribution. This is not a claim of a fully source-built or bit-for-bit reproducible IPA.

The native script expects a fresh Apple Silicon macOS checkout, Python 3.12 or newer, and Xcode 27. Source extraction refuses existing destination directories. Downloads stay in `.build/runtime-downloads`; the media SDK stays inside the iOS project's `.build/media-sdk`. Existing developer files and global temporary SDK directories are not reused. `IRIDIUM_BUILD_JOBS` defaults to two to limit parallel compiler memory use. Homebrew build tools are runner-provided, not version-locked by this change.

Inspect the sequence without downloading, compiling, or modifying files:

```sh
python3 ci/fetch-runtime-inputs.py --plan
bash ci/prepare-native-runtime.sh --plan
```

The legacy post-build stage also requires `Amethyst-iOS/Natives/resources/Frameworks/libEGL.framework` and `libGLESv2.framework`. That source/build chain is not in this monorepo. Their absence is now reported before Xcode. Do not upload local copies to bypass it; establish their exact source, build recipe, and notices first.

The Xcode and unsigned packaging steps remain after the readiness check. No new app or runtime compilation has been run to verify these recipes. Do not treat static checks as a successful runtime build.
No IPA workflow was dispatched while adding it. Static trigger checks and synthetic package rejection tests were run without compiling an app. Run them with `python3 -B -m unittest discover -s ci -p 'test_*.py'`.

The package step rejects certificates, provisioning profiles, private-key text, device identifiers, missing helper executables, and escaping symlinks. It strips existing vendor code signatures in a temporary staging copy and checks each native executable before creating the IPA. It never imports a keychain or accesses signing credentials.

## Runner and cost

GitHub documents free standard hosted runners for public repositories. The `xcode-27` standard preview image provides Xcode 27. Do not use `xcode-27-xlarge` or other paid larger runners. Verify the image at the time of implementation. Standard runners have finite memory, disk space, and job duration; the full Wine/FEX/media build must be measured before promising it fits.

Store source in Git without LFS. Use short-lived Actions artifacts for test IPAs, and GitHub Release assets for published IPAs and corresponding-source archives. Review artifact/cache storage limits; free runner time does not mean unlimited storage.

## Required preparation

1. Make the runtime, media SDK, ARM64EC modules, FEX, DXMT, and crypto-library stages build from pinned sources on a clean runner. The native stages are scripted; Windows modules, prefix generation, legacy packaging, and external graphics still need clean-runner preparation.
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
