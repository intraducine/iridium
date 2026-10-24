# Build a sideloading IPA

Local builds and **Actions → Build sideloading IPA** build the Iridium-owned app
against the pinned native runtime. Both use `ci/madeira-frontend.py`.
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
Both workflows select `/Applications/Xcode_27.app/Contents/Developer` (Xcode
27.0) before checking tools or building. A runner image's default Xcode change
must not change the compiler silently. A missing pinned Xcode stops the job.
Update this selection deliberately in both workflows. Compiler and SDK changes
still require matching new component artifacts and source-check results.
Every workflow build includes all integrated engines, including Dolphin,
Azahar, Play!, and Flycast. Select `main` or the reviewed branch intended for
testing, and check its exact commit when selecting source-check results.
Push the reviewed commit, then use:

```sh
python3 ci/dispatch-build.py
```

This defaults to a fast test build. It builds the complete app and checks the
IPA, but skips the full source archive and release audit uploads. Source checks,
component validation, privacy checks, package blockers and signature checks stay
on.

For a release candidate, use `python3 ci/dispatch-build.py --release`, or set
`release_build=true` in GitHub. This also collects and checks the full matching
source archive and retains the link audit. This mode does not publish a release.
Use a release build for public distribution; do not promote a test artifact
without the matching source and release checks. See [the release policy](releasing.md).

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

Successful Madeira native/i386, PSP, SameBoy, shared player, Dolphin, Azahar,
Play! and Flycast builds are uploaded **before** app compilation and packaging.
Each compiler stage has its own artifact, retained for 14 days. PSP's saved
output includes FFmpeg/MoltenVK's linked player, resources, notices and locked
source archives. Console outputs retain generated inputs needed by source audits.
An app-only edit restores these components without invoking their compilers.
Each component's source, adapter, recipe and toolchain still invalidate its output.
The app step validates the prepared PSP component and reuses the verified SameBoy
archive. Source collection and final app/package audits still run for every build.
Reuse requires a trusted manual producer, matching source pins and recipes,
matching compiler/SDK details, checksums and workspace paths. The saved
Madeira completion record also checks age and every retained output. The i386 stage
rebuilds missing, changed or expired outputs. Native reuse requires a complete
schema-2 receipt; on a miss, existing unverified compiler substages stop before
bootstrap. Reusing an artifact does not upload another copy or extend its lifetime.
Set `reuse_assets=false` for a fresh hosted build.
Local Madeira completion records use the same 14-day limit.

The workflow also caches runtime Git objects and up to 3 GiB of compiler
results. Submodule checkout still selects and verifies the pinned revisions.
CMake engine builds use ccache, which
checks the actual compiler, arguments, source and headers. Changed recipes
still invalidate complete component artifacts; unchanged compilation units can
reuse compiler results. Neither cache changes build flags or relaxes receipt,
source, package or release checks. Both caches start empty on their first run.
Azahar's source overlays and target setup have separate recipe files, so edits
to those files do not invalidate Dolphin, Play! or Flycast. Azahar artifacts
retain its expanded source and MoltenVK verification inputs as well as binaries.

Native checkpoint packaging validates the completed receipt and every recorded
output before creating a producer artifact. Restoration validates the extracted
native generation against current recipe/tool and complete tracked upstream source
identities before copying any file
into the checkout. The following native step uses `--reuse-only` after a restore,
so a rejected restored generation cannot silently trigger compilation. Receipt
output paths remain relative; existing producer, toolchain, workspace, checksum
and retention checks still apply. Legacy native receipts without constituent
identities and explicit completion state require a complete authorized rebuild.
Leaf and ancestor destination symlinks, including links to other paths inside the
checkout, are rejected before any restore copy. A cache miss with existing native
compiler substages fails closed rather than minting a receipt around intermediates
whose provenance does not match. No cache cleanup or receipt migration is performed.

The native stage copies rebuilt GnuTLS, Hogweed, Nettle and GMP archives from
their toolchain prefix into the app's linked paths. Its completion record checks
both copies. Failed ntdll compilation stops before archiving or installing old
objects. A failed bulk i386 build retries every selected target, including
existing DLLs; a failed retry stops installation and completion recording.

App code and docs do not invalidate compiler outputs. In
`ci/madeira-frontend.py`, reviewed app-staging and presentation function bodies
are excluded from the compiler comparison. Compiler recipes, shared helpers,
imports, globals, function signatures and command-line routing still invalidate
both components. Unrecognized source layouts or dependencies use the stricter
whole-file comparison. The i386 completion-record format and producer trust checks
are unchanged. Native reuse requires the schema-2 evidence described above;
matching retained builds can be reused without recompilation.

## Source and package checks

Source checks use the same Xcode 27 runner as the manual app build for Swift,
Apple Foundation, CoreGraphics and Objective-C ARC. They initialize the pinned
frontend and console sources and verify Swift, Clang and zstd before running the
suite. This job tests source and host fixtures; application and IPA builds remain
manual.

With `release_build=true`, the workflow records the final app's Mach-O, PE and ELF
files and its static link inputs. It collects the exact repository and initialized dependency
snapshots, FreeType source, locked LLVM and runtime source archives, pairing
crate sources, generators, build instructions and notices into
`Iridium-corresponding-source.tar.gz`. Source collection fetches and verifies the
pinned FreeType revision when a reused native build leaves its source checkout
absent. Existing checkouts must match the pin and pass the source-change check
before collection.
`COMPONENT-MANIFEST.json` maps packaged binaries to their components and records
source revisions and release hashes.
Its `source_exclusions` receipt records the exact path, SHA-256, pinned upstream
URL and reason for omitting PPSSPP's public Windows UWP signing fixture and
unused prebuilt FFmpeg archives. The codec source is included and the native
builder compiles it; none of those omitted archives are link inputs. The
checkout remains unchanged, and native iOS source and required build inputs remain
in the archive. The privacy scan accepts only the reviewed path and bytes in
`ci/public-signing-fixtures.json`; changed or additional signing files fail both
the scan and source collection. The unused archive manifest also requires exact
paths and hashes; changed bytes fail exclusion. Other private-data checks remain in force.
In release mode, an unknown binary, absent runtime link map or missing source
input stops IPA upload. Unresolved build/package blocker records stop both modes.

Both modes retain the IPA, checksum and signature report. Release mode also
retains the matching source package and checksum, and link maps with the binary
inventory. Actions artifacts
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


## Replace the native PSP component

The app and native component must both use ABI 2. Rebuild/relink both when changing
the boundary; the loader rejects ABI 1 components. The shared Iridium player owns
all frontend controls and menus. Its resolution and save-state requests apply on
resume in the native render owner. The phone UI and God of War acceptance still
require separate device tests; a component/app build does not establish them.

The PSP engine uses the exact PPSSPP v1.20.4 source/dependency pins in its build
receipt, upstream FFmpeg codec sources and the source-built MoltenVK closure in
`ci/moltenvk-source-inputs.json`. Required source downloads are included under
`.build/runtime-downloads/` in the corresponding-source archive. Apple SDKs and
Xcode remain external prerequisites.

Edit the supplied sources or the declared embedding hooks, rebuild the component,
then run the app and package steps. With `--reuse-psp-component`, the app step validates the component receipt
and copies it; it does not rebuild and overwrite a replacement PSP library.

```sh
python3 ci/build-ppsspp-native.py --output .build/ppsspp/iphoneos --sdk iphoneos
python3 ci/madeira-frontend.py app --reuse-psp-component
python3 ci/package-unsigned-ipa.py \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app \
  .build/relinked-native-psp-ipa
```

The builder verifies expanded MoltenVK sources against the locked archives and
records its exact final link inputs. MoltenVK source edits require updating the
source-input manifest and hashes with the intended replacement source closure.
FFmpeg is built from its included source with the selected LGPL codec recipe.
The receipt records those codec configuration arguments and rebuilt archive
hashes. Preserve all applicable GPL/LGPL/OFL/Apache and other upstream notices.
The public-distribution review limits in LICENSING.md still apply to the combined
app and proprietary converter interpretation; the recipe is not a determination
of combined-work classification.

Native PSP resources use the four owned atlas files identified by
`ci/psp-atlas-resources.json`. Other upstream assets retain their exact bytes.
The component receipt includes the atlas receipt; corresponding source includes
all eight font inputs, full notices and the generation recipe, and omits the
four exact superseded upstream atlas files. The source checkout remains intact.
Generation is separate from an iOS build and requires Python 3.14, CMake, Ninja
and a host C++ compiler:

```sh
python3 ci/build-ppsspp-atlases.py --fetch --output .build/psp-atlas-review
```

Use a fresh output directory. Review its receipt, parser checks, metrics and
actual-size multilingual PNG proofs before copying the four outputs into
RuntimeSupport/PPSSPPAtlases and the receipt into ci/psp-atlas-resources.json.
Both atlas textures remain 2048x2048 with their original pixel formats. The
replacement keeps all existing glyph lookups and image IDs/sizes/texels.
The horizontal line heights are 51.5 UI pixels (previously 49) and 37.5 PSP
pixels (previously 37.4375); verify actual UI wrapping and game dialogs on device.
The resource patch does not alter runtime pins, backends, saves, input or media.
It does not replace an already delivered personal IPA or establish GOW loading.
