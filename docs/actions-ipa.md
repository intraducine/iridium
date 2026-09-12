# Build an unsigned IPA

Use **Actions → Build unsigned IPA → Run workflow**. Select the branch to build.
For a checked local checkout, `python3 ci/dispatch-build.py` starts the workflow
and verifies that GitHub builds the selected commit. Builds are manual; the
source privacy check runs on pushes and pull requests.

The workflow builds the app without signing. Packaging requires the checks in
`ci/binary-release-blockers.json` and `ci/binary-package-blockers.json` to pass.
A stopped packaging step does not mean that compilation failed. Inspect the
individual steps and their logs.

An unsigned IPA must be signed with a suitable sideloading tool before it can
be installed. Sign the app and its helper extensions. JIT, game playback, audio,
and input need separate device tests.

## Build requirements

Use a fresh checkout, Python 3.12 or newer, and Xcode 27. The workflow installs
its host tools and prepares dependencies. Follow its commands for a local build;
generate the app project with `iridium/apps/ios/stikjit.yml`.

The Linux job prepares Wine userland, exact Debian source packages, and copyright
notices. The macOS jobs prepare native libraries, Wine Windows modules, FEX,
DXMT, ANGLE, GStreamer, StikJIT/idevice, and a temporary prefix. Prefix preparation
uses a separate build directory and does not modify player saves.

Archive pins are in `ci/runtime-inputs.json`. Git dependencies use committed
revisions. Host tools and the Debian image are not fully version-locked, so the
build does not promise byte-for-byte reproducibility.

Inspect inputs and run local checks before compilation:

```sh
python3 ci/fetch-runtime-inputs.py --plan
bash ci/prepare-native-runtime.sh --plan
python3 -B -m unittest discover -s ci -p 'test_*.py'
```

With Xcode selected, `bash ci/prepare-media-sdk.sh --preflight` checks the
prepared Cerbero compiler configuration without compiling the full media SDK.
Use the same isolated Python environment for media and source-package checks.

## Saved build outputs

Successful native, Wine, Windows, graphics, and JIT builds are uploaded before
later packaging steps. Linux and media outputs are also retained. A packaging
failure does not discard these completed components.

Artifacts expire after seven days. Reuse does not create another copy or extend
that lifetime. Missing or expired artifacts trigger a rebuild. Reuse requires
matching source inputs, build recipes, toolchain details, and archive checksums.
Changes to shared inputs can require more than one component to rebuild.

The application is built and audited after component restoration. Set
`reuse_assets=false` and leave explicit media/Linux overrides empty to request
a fresh build. Source collection and release checks still run when components
are reused.

## Source and binary checks

The source artifact contains the selected repository revision, dependency source,
local patches, build files, and notices. Its checksum is in `SOURCE-SHA256SUMS`.
The workflow retains this artifact and app link maps for review before IPA
packaging. Source collection alone does not prove that every binary is covered.

The package check rejects signing files, unreviewed private-key material, device
identifiers, missing helpers, and symlinks outside the app. Only exact reviewed
public test-library hashes have a private-key scan exception. Vendor signatures
are removed in a staging copy; the original build output stays intact.

Do not supply signing keys, provisioning profiles, pairing records, Apple account
credentials, or private device logs to Actions. Release the IPA with matching
source, checksums, notices, build instructions, and signing instructions. See the
[release policy](releasing.md) and [license guide](../LICENSING.md).

## Rebuild and relink a modified media library

Use a separate working directory. Keep the original source archive, checksums
and test app. Do not use a player's game folder or prefix as a build directory.
Install Xcode and host tools separately; they are not supplied in the source
archive. Start with the exact release source and its component patches.

The app links the static library at
`iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a`.
The headers come from the same slice. To test library replacement:

1. Prepare the normal build inputs using the release workflow's commands. Keep
   the prepared Cerbero tree and generated `.build/cerbero-ci.cbc` configuration.
2. Make the library change in a Cerbero recipe patch, and rebuild the affected
   recipe and GStreamer package using Cerbero. Keep the patch in the source
   package. A patch to a temporary extracted source directory can be lost when
   Cerbero extracts that source again.
3. Export the XCFramework using the `package` and `xcframework` commands in
   `ci/prepare-media-sdk.sh`. In this separate test checkout, replace the media
   SDK slice with that output, including its headers. Do not restore a cached
   media artifact over the modified output.
4. Run `python3 ci/check-media-link.py` with the modified `libGStreamer.a` path.
   Generate the Xcode project with `xcodegen generate --spec
   iridium/apps/ios/stikjit.yml`, then repeat the unsigned Xcode build command
   from the workflow using a new DerivedData directory.
5. Inspect the app link map and library checksum to confirm the modified input
   was linked. Run the modified code on the device with the user's signing
   setup. Record what changed and the observed result.

This procedure is a release verification requirement, not a completed test.
The media probe confirms a link only; it does not replace the complete app
rebuild, final binary review or device playback check.

## Verify a modified GMP library

Run `python3 ci/dispatch-build.py --verify-lgpl-relink` to request a separate
unsigned app build with modified GMP. The test checks the supplied GMP source
checksum, rebuilds it with a marker in `mpn_add_n`, and checks for that marker
in the linked MadeiraNative framework. It restores the original archive before
packaging. Results are retained in `lgpl-relink.json` with the app audit files.
The test covers GMP source replacement and app linking, not device execution
or replacement of every other LGPL library.
