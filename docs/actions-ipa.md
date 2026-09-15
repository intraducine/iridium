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

The app audit artifact includes `static-inputs.json`: the archive checksum and
linked object names for each static library referenced by the final app link
maps. Collection runs immediately after the app build and fails if a referenced
archive is missing. It also records each map's checksum. Keep these records with
`binaries.json` and the corresponding source inventory. They identify build
inputs; they do not establish license coverage or verify replacement/relinking.
Do not use hashes collected later from changed archives as proof of an earlier
link. ANGLE's separately built framework inputs need their own link evidence.

For a pinned archive supplied as `NAME.source-archive`, restore it into a fresh
checkout without downloading it:

```sh
python3 ci/fetch-runtime-inputs.py --only gmp \
  --source-archive /path/to/corresponding-source/gmp.source-archive
```

The command checks the pinned checksum and refuses to overwrite changed input.
A missing or damaged supplied archive fails without a download fallback. This
option restores one pinned archive; it does not restore the complete source
package, vendor trees, or host tools.

Use a separate working directory. Keep the original source archive, checksums
and test app. Do not use a player's game folder or prefix as a build directory.
Install Xcode and host tools separately; they are not supplied in the source
archive. Start with the exact release source and its component patches.

Keep the supplied `sources` directory with the restored Cerbero tree. The cache
restore patches use its nested Meson archives and Cargo vendor trees. Meson
checks archive hashes; Cargo uses Cargo.lock and locked, offline dependency
resolution. Missing inputs must fail the offline rebuild. Use a physical build
path rather than a symlink so Autoconf does not create self-referencing links.

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

This is a usable replacement procedure and an optional engineering test.
The source package must support replacement; a marker test for every library
and a byte-identical rebuild are not general license requirements. The media
probe confirms a link only. Record source completeness, distribution permission
and device behavior separately.

## Optional modified GMP test

Run `python3 ci/dispatch-build.py --verify-lgpl-relink` to request a separate
unsigned app build with modified GMP. The test checks the supplied GMP source
checksum, rebuilds it with a marker in `mpn_add_n`, and checks for that marker
in the linked MadeiraNative framework. It restores the original archive before
packaging. Results are retained in `lgpl-relink.json` with the app audit files.
The test covers GMP source replacement and app linking, not device execution
or replacement of every other LGPL library.

## Replace native and Windows components

Run these commands from the extracted release checkout, after preparing its
pinned dependencies and toolchains with the workflow's build steps. Use a
separate working copy. Keep the original release files and record your changes.
Commands below reuse configured build directories; changes to configuration or
headers can require reconfiguration and rebuilding dependents. They do not fetch
an old binary cache over your replacement.

Set the same Xcode used by the release:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export IRIDIUM_BUILD_JOBS=2
```

For native static libraries, use the component's recorded build command and
replace the archive at the path recorded in `static-inputs.json`. For example,
the Madeira Wine server recipe also stages its archive:

```sh
bash testrepos/Madeira/build/wineserver/build.sh
```

For Wine native media or loader changes, regenerate the media wrapper archives
used by the final app, rather than replacing only the unused base archive:

```sh
sh iridium/apps/ios/Scripts/build_media_runtime.sh
```

For Wine Windows DLLs, compile and then stage with the existing architecture
checks. Staging Wine also restores FEX and DXMT over Wine's placeholders:

```sh
bash ci/compile-wine.sh
bash ci/prepare-windows-runtime.sh
```

For FEX or DXMT changes, rebuild the Windows component stage and then stage it:

```sh
bash ci/compile-windows-modules.sh
bash ci/prepare-windows-runtime.sh
```

The compiler step builds FEX's `arm64ecfex` target to
`testrepos/Madeira/FEX/build-arm64ec/Bin/libarm64ecfex.dll`, copies it to the
retained transfer location, and staging names it `arm64ec-windows/xtajit64.dll`.
It also builds the four DXMT modules for both aarch64 and arm64ec. Do not copy
Wine's placeholder `xtajit64.dll` over the translator. The staging check rejects
that placeholder and checks the required architecture views. Prepared prefix
and other runtime files are prerequisites; do not use a player's prefix.

For GStreamer/media replacement, use the preceding Cerbero instructions to
rebuild and export the framework. Replace the SDK slice including its headers,
then run `build_media_runtime.sh` above when its headers or wrapper inputs change.

After any replacement, generate and build the complete unsigned app:

```sh
xcodegen generate --spec iridium/apps/ios/stikjit.yml
xcodebuild -project iridium/apps/ios/IridiumStikJIT.xcodeproj \
  -scheme Iridium -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/replacement-app \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= EXPANDED_CODE_SIGN_IDENTITY= \
  PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= \
  LD_GENERATE_MAP_FILE=YES build
python3 ci/collect-app-link-audit.py \
  .build/replacement-app/Build/Products/Release-iphoneos/Iridium.app \
  .build/replacement-audit/binaries.json \
  --link-maps .build/replacement-app/Build/Intermediates.noindex
```

Check the replacement archive or DLL hash against the new link inventory or
bundle file, not against the original release hash. For static code, inspect
the selected members and symbols; a marker is one optional way to do this.
Use the recipient's own supported signing and JIT setup for device execution.
No maintainer key is required by these unsigned build commands. Installation
rights and runtime behavior must be assessed separately; these commands do not
establish either. They are not a claim that all replacement variants were tested.

## Local incremental app builds

With the runtime dependencies staged, run from the repository root:

```sh
bash ci/build-local-ipa.sh
```

This local setup targets iOS 27 because its retained media SDK requires iOS 27.
Do not use its output as an iOS 26 compatibility build.

The script uses Xcode beta by default. Set `DEVELOPER_DIR` to choose another
installed Xcode. It builds without signing and checks the package before writing
a new `.build/local-ipa-output.XXXXXX/Iridium-unsigned.ipa` and its checksum.
The command prints the output path and preserves earlier IPAs.

Keep `.build/local-ipa` between builds. Xcode reuses unchanged compilation outputs;
the script does not run a clean build. Packaging failures leave those outputs
available. To retry packaging alone after correcting a packaging issue:

```sh
python3 ci/check-ipa-prerequisites.py --package
output=$(mktemp -d "$PWD/.build/local-ipa-output.XXXXXX")
python3 ci/package-unsigned-ipa.py \
  .build/local-ipa/Build/Products/Release-iphoneos/Iridium.app "$output"
```

This command rebuilds the app, not its precompiled runtime dependencies. After
changing Wine, FEX, DXMT, media, or the dependency toolchain, rebuild and stage
those inputs with the component instructions above before running it. Missing
inputs stop the build. The presence check does not prove that existing libraries
match changed dependency source. Keep matching source and notices for any IPA
that you distribute. Device testing remains separate.
