# Build a sideloading IPA

Local builds and **Actions → Build sideloading IPA** build the pinned Madeira
app with Iridium's presentation overlay. Both use `ci/madeira-frontend.py`.
The source revision is recorded in `UPSTREAM-SOURCES.json` and in the app.

## Local build

Use an Apple Silicon Mac, Homebrew, Python 3.11 or newer, and full Xcode 27
with its iPhoneOS SDK. From the repository root:

```sh
bash ci/build-madeira-ipa.sh "$HOME/Downloads/Iridium-build"
```

The result is `Iridium-build/Iridium-unsigned.ipa`, its checksum, and a signature
report. Logs stay under `.build/local-build-logs/`. The builder checks and
installs missing host tools before it compiles. It downloads Metal only when
the installed compiler cannot run. Set `DEVELOPER_DIR` to choose Xcode.
See [local build details](local-ipa-build.md).

The app uses Madeira's Debug configuration. Packaging strips debug symbols.
`ENABLE_DEBUG_DYLIB=NO` puts the runtime link in the main executable so its final
link map includes the static libraries. It does not change compiler optimization.
The main app target has an iOS 18.0 minimum. Madeira's JIT helper retains its
upstream iOS 26 minimum. Use external JIT on earlier versions.

## GitHub Actions

Builds are manual. Source checks can run on pushes and pull requests.
Push the reviewed commit, then use:

```sh
python3 ci/dispatch-build.py
```

The command builds the current branch and passes its full commit as
`expected_sha`. It checks the actual dispatched commit and cancels a mismatched
run. The workflow also checks this value before downloads or compilation.
You can run the workflow in GitHub by selecting a branch and supplying its full
40-character commit. Do not rerun an old commit to test a new fix.

The workflow initializes the pinned Madeira, Wine, FEX, DXMT and Dock sources.
It uses the same host setup, locked toolchain downloads, native recipes, i386
build, overlay, app build and package tool as the local command. Steam and media
use Madeira's implementations. FFmpeg 7.1.1 replaces the separate Cerbero SDK in
this target. The tracked converter library comes with Madeira's Apple notice;
no maintainer account or signing credentials are used.

## Saved build outputs

Successful native and i386 builds are uploaded **before** app compilation and
packaging. Each compiler stage has its own artifact, retained for 14 days.
Reuse requires a trusted manual producer, matching source pins and recipes,
matching compiler/SDK details, checksums and workspace paths. The saved
completion record also checks age and every retained output. A missing, changed
or expired output triggers a rebuild. Reusing an artifact does not upload another
copy or extend its lifetime. Set `reuse_assets=false` for a fresh hosted build.
Local completion records use the same 14-day limit.

The native stage copies rebuilt GnuTLS, Hogweed, Nettle and GMP archives from
their toolchain prefix into the app's linked paths. Its completion record checks
both copies. Failed ntdll compilation stops before archiving or installing old
objects. A failed bulk i386 build retries every selected target, including
existing DLLs; a failed retry stops installation and completion recording.

App code and docs do not invalidate compiler outputs. Changes to
`ci/madeira-frontend.py` currently invalidate both components because that file
owns both recipes. Packaging fixes alone do not require another native build.

## Source and package checks

The workflow records the final app's Mach-O, PE and ELF files and its static
link inputs. It collects the exact repository and initialized dependency
snapshots, FreeType source, locked LLVM and runtime source archives, pairing
crate sources, generators, build instructions and notices into
`Iridium-corresponding-source.tar.gz`. Source collection fetches and verifies the
pinned FreeType revision when a reused native build leaves its source checkout
absent. Existing checkouts must match the pin and pass the source-change check
before collection.
`COMPONENT-MANIFEST.json` maps packaged binaries to their components and records
source revisions and release hashes.
Its `source_exclusions` receipt records the exact path, SHA-256, pinned upstream
URL and reason for omitting PPSSPP's public Windows UWP signing fixture. The
checkout remains unchanged, and all iOS Libretro source and build inputs remain
in the archive. The privacy scan accepts only the reviewed path and bytes in
`ci/public-signing-fixtures.json`; changed or additional signing files fail both
the scan and source collection. Other private-data checks remain in force.
An unknown binary, absent runtime link map, missing source input or unresolved
entry in the repository's build/package blocker records stops IPA upload.

Retained artifacts include the IPA and signature report, the matching source
package and checksum, and link maps with the binary inventory. Actions artifacts
expire. For a public release, host the matching source package and required
notices permanently beside the IPA. Follow [the release policy](releasing.md).

The package removes existing signatures and puts an anonymous ad-hoc
`com.apple.developer.kernel.increased-memory-limit=true` carrier on the main
app. It checks the entitlement, empty CMS payload, absent team identity,
resource seal and nested executable signatures. This carrier is a request to
the recipient's signer, not permission to install. Re-sign the app, helper and
frameworks with a suitable sideloading tool. Check the final provisioning
profile and installed entitlements. JIT must be enabled before launching a game.

## Rebuild from the supplied source package

Verify `SOURCE-SHA256SUMS`, then extract the archive:

```sh
shasum -a 256 -c SOURCE-SHA256SUMS
tar -xzf Iridium-corresponding-source.tar.gz
cd iridium
bash ci/build-madeira-ipa.sh "$HOME/Downloads/Iridium-rebuilt"
```

The archive has all initialized runtime source trees and a `SOURCE-REVISIONS.json`
record. The builder accepts this source layout without Git metadata. It keeps
Apple SDKs, Xcode and host compilers external. LLVM and runtime source downloads
are retained under `.build/runtime-downloads/`; LLVM-MinGW remains a locked
external compiler download. Pairing's vendored Cargo sources use a relative
configuration and remain usable after extraction.

## Replace native libraries and media

Build the source package once to prepare headers and tools. Edit the supplied
library source, run its recipe, then relink the app. Native output archives go
in `vendor/Madeira/app/Madeira/`; FEX native archives stay in `FEX/build-ios/`.
For example:

```sh
source .build/madeira-build-tools.env
bash vendor/Madeira/build/wineserver/build.sh
bash vendor/Madeira/build/ntdll-unix/build.sh
bash vendor/Madeira/build/win32u-unix/build.sh
bash vendor/Madeira/build/gnutls-ios/build.sh
cp vendor/Madeira/toolchains/gnutls-ios/lib/lib{gnutls,hogweed,nettle,gmp}.a vendor/Madeira/app/Madeira/
bash vendor/Madeira/build/ffmpeg/build.sh --reconfigure
python3 ci/madeira-frontend.py app
python3 ci/package-unsigned-ipa.py \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app \
  "$HOME/Downloads/Iridium-relinked"
```

Run the recipes for the libraries you changed. FFmpeg uses an LGPL-only
configuration and Apple audio/video decoders. Do not enable GPL or nonfree
codecs without reviewing their terms. The app step copies the replacement
archives into the generated project and relinks. It does not run the native
cache stage or overwrite a replacement archive. Use the supplied source layout
for source changes; a normal Git checkout rejects changes to the pinned upstream
sources until the overlay and dependency pin are reviewed.

## Replace Wine, DXMT and FEX Windows modules

Keep each architecture in its own farm. Do not stage a 32-bit DLL into
`arm64ec-windows` or `aarch64-windows`.

```sh
source .build/madeira-build-tools.env
bash vendor/Madeira/build/wine-pe/build-modules.sh kernelbase shell32
bash vendor/Madeira/build/wine-pe/build-ntdll.sh
bash vendor/Madeira/build/fex-arm64ec/build.sh
bash vendor/Madeira/build/fex-wow64/build.sh
bash vendor/Madeira/build/wine-i386/build.sh
python3 ci/madeira-frontend.py app
```

The Wine scripts stage ARM64EC modules. The FEX scripts stage `xtajit64.dll`
under `arm64ec-windows` and `xtajit.dll` under `aarch64-windows`. The i386 recipe
builds and stages Wine and DXMT's 32-bit modules. For 64-bit DXMT replacements,
use the cross-build settings in `vendor/Madeira/dxmt/` and stage the rebuilt
DLLs in the matching farm. Rebuild native DXMT with
`vendor/Madeira/build/dxmt-ios/build.sh`; `build_native()` in
`ci/madeira-frontend.py` shows the shader preparation and combined-archive link.
Then run the app and package steps above. Preserve the applicable notices.
Replacement binaries can have different checksums. Byte-identical builds,
per-library marker tests and a separate application object kit are not required
when the complete source and build material provide a usable relink path.
