# Build an IPA

Use an Apple Silicon Mac, full Xcode 27 with Metal tools, Homebrew, Python 3.11+,
and Rust. Run commands from the repository root. Set `DEVELOPER_DIR` to select
Xcode. The main app targets iOS 18+; helper requirements are in the [JIT guide](../iridium/docs/builtin-stikjit-ios27.md).

## Local build

```sh
bash ci/build-madeira-ipa.sh "$HOME/Downloads/Iridium-build"
```

The builder prepares pinned dependencies and missing host tools, builds the
Debug app, strips debug sections, and writes `Iridium-unsigned.ipa`, `SHA256SUMS`,
and `ipa-signature-audit.json`. It does not install the app. Logs stay in
`.build/local-build-logs/`.

This script builds Windows, GB/GBC, and PSP. To add Dolphin, Azahar, Play!, and
Flycast, continue with the [console build steps](console-engines.md#build-and-replace),
then package the rebuilt app.

To inspect tools without installing them:

```sh
python3 ci/local_build_tools.py --madeira --check --write-env .build/madeira-build-tools.env
```

Set `IRIDIUM_AUTO_INSTALL_BUILD_TOOLS=0` to refuse automatic tool installation.
Do not delete build outputs to repair a packaging error.

## GitHub Actions

Push the reviewed commit, then run:

```sh
python3 ci/dispatch-build.py
```

This starts **Build sideloading IPA** for the current branch and exact HEAD.
The helper and workflow verify the full `expected_sha`. To build through GitHub,
select the intended branch and supply its 40-character commit.

Default test mode includes the full app and all engines, source/component checks,
privacy checks, package blockers, and signature checks. Release mode also retains
matching source and link audits:

```sh
python3 ci/dispatch-build.py --release
```

Neither mode publishes. See [releasing.md](releasing.md) before distribution.
Both workflows select `/Applications/Xcode_27.app/Contents/Developer`; changing
compiler or SDK requires new matching checks and components.

## Reuse

Madeira native/i386 and each console component have separate saved outputs,
retained for 14 days before app packaging. Reuse checks source pins, recipes,
toolchain, platform, workspace paths, receipts, and output hashes. App-only edits
can reuse matching engine builds. Set `reuse_assets=false` for a fresh hosted run.
Compiler caches can reuse unchanged units after a component cache miss.

Local native reuse can be checked without compiling:

```sh
source .build/madeira-build-tools.env
python3 -B ci/madeira-frontend.py native --reuse-only
```

Native schema-2 receipts record completed inputs and outputs. Old, partial,
expired, or changed receipts fail validation. Restores reject symlinks and verify
source inventories before copying. Do not reseal partial outputs; use a fresh
checkout for a full rebuild when required.

## Signing and output

The package's main app has an anonymous ad-hoc carrier containing only
`com.apple.developer.kernel.increased-memory-limit=true`; helpers remain unsigned.
Recipients must sign the app and all extensions/frameworks and verify their final
profile and entitlements. No maintainer signing credentials enter the build.
LiveContainer uses its host process's rights.

## Rebuild from release source

```sh
shasum -a 256 -c SOURCE-SHA256SUMS
tar -xzf Iridium-corresponding-source.tar.gz
cd iridium
bash ci/build-madeira-ipa.sh "$HOME/Downloads/Iridium-rebuilt"
```

The archive includes dependency trees, locked source downloads, patches,
generators, notices, and revision/component manifests. It supports builds without
Git metadata. Xcode, Apple SDKs, and host toolchains remain external prerequisites.
Pairing Cargo dependencies use a relative vendored-source configuration.

## Replace native libraries

Build the supplied source package once to prepare headers and tools. Change the
library source, run its recipe, then relink and package. For example:

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

Run only the recipes for changed libraries. The app step relinks without running
the native cache stage. FFmpeg uses an LGPL-only configuration; review terms
before enabling other codecs. A normal Git checkout rejects unreviewed changes
to pinned source; use the supplied source layout for replacements.

For Windows modules, keep architectures in separate farms:

```sh
bash vendor/Madeira/build/wine-pe/build-modules.sh kernelbase shell32
bash vendor/Madeira/build/wine-pe/build-ntdll.sh
bash vendor/Madeira/build/fex-arm64ec/build.sh
bash vendor/Madeira/build/fex-wow64/build.sh
bash vendor/Madeira/build/wine-i386/build.sh
```

These stage ARM64EC, aarch64, and i386 outputs in their matching directories.
Use `vendor/Madeira/dxmt` cross-build settings for PE DXMT and
`vendor/Madeira/build/dxmt-ios/build.sh` for native DXMT. The native build recipe
in `ci/madeira-frontend.py` supplies shader preparation and archive linking.
Relink with the app/package commands above.

## Replace PSP and other console engines

```sh
python3 ci/build-ppsspp-native.py --output .build/ppsspp/iphoneos --sdk iphoneos
python3 ci/madeira-frontend.py app --reuse-psp-component
```

The app validates the PSP ABI and receipt before copying the replacement.
Rebuild both sides when changing the interface. FFmpeg and MoltenVK are built
from locked source; source changes require updated manifests and hashes.
See [console-engines.md](console-engines.md) for the other engine recipes.

PSP atlas regeneration is separate and needs Python 3.14, CMake, Ninja, and C++:

```sh
python3 ci/build-ppsspp-atlases.py --fetch --output .build/psp-atlas-review
```

Use a fresh output directory. Review parser checks, glyphs, icon pixels, metrics,
and multilingual proofs before updating the four atlas files and their receipt.
See [the atlas recipe](../ci/psp-atlas-host/README.md).

Preserve notices and deliver matching source with redistributed binaries.
[LICENSING.md](../LICENSING.md) records unresolved combined-app terms. Replacement
libraries may have different hashes; release hashes identify shipped files.
