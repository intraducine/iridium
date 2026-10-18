# Local IPA builds

From the repository root:

```sh
git pull --ff-only
bash ci/build-madeira-ipa.sh "$HOME/Downloads/Iridium-build"
```

Use `git pull` only on the branch you intend to update. The build command does
not reset source, delete saves or install the app. It builds the pinned Madeira
app with Iridium's presentation overlay. GitHub Actions uses the same builder.
See [build, source and replacement instructions](actions-ipa.md).

Use an Apple Silicon Mac, Homebrew, Python 3.11 or newer, and full Xcode 27.
Set `DEVELOPER_DIR` if you need to select a different Xcode installation.
The tool preflight installs missing Homebrew tools, exports keg-only paths,
and downloads the Metal toolchain only if it is missing. It does not upgrade
all installed packages or change shell startup files.

To check tools without installing them:

```sh
python3 ci/local_build_tools.py --madeira --check --write-env .build/madeira-build-tools.env
```

The builder initializes only the needed Madeira runtime submodules. It uses
locked LLVM 15.0.7 and LLVM-MinGW downloads, the tracked FFmpeg/crypto source
archives, pinned FreeType, and Madeira's Cargo lockfile. It does not need the
separate .NET Steam framework or Cerbero SDK.

Native and i386 completion records live in `vendor/Madeira/.build/`. Successful
outputs are reused for 14 days when inputs and output hashes match. App builds
use `.build/madeira-frontend-derived/`; generated frontend source lives in
`.build/madeira-frontend/`. Packaging failures keep these outputs. Do not delete
them to fix a packaging problem.

To validate native reuse without falling back to compilation, source the prepared
tool environment and run:

```sh
source .build/madeira-build-tools.env
python3 -B ci/madeira-frontend.py native --reuse-only
```

This reports every recipe/tool/input mismatch, expired or incomplete completion
record, and missing/changed output, then exits nonzero before bootstrap on a miss.
It does not refresh a stamp or repair outputs. Ordinary `native` remains a build
operation: after a miss it requires fresh compiler substage directories before it
can compile. Existing LLVM, crypto, wineserver or other native intermediate outputs
without a valid complete receipt stop before bootstrap. Use an independent fresh
checkout; do not delete shared outputs or reseal them with a new timestamp.

New schema-2 native completion records contain constituent recipe/file digests, individual
tool versions and resolved executable paths (plus Bison/Flex binary digests), relative
output digests and explicit completion state. Bison older than 3.0 is rejected
before bootstrap. Old records without this evidence fail reuse validation; do not
relabel or reseal partial outputs to migrate them. A successful complete native
build creates the new record atomically.

Receipts also bind all tracked files and modes in the pinned Madeira dependency
trees and FreeType, including parser/lexer grammars and build configuration. Tool
preparation obtains the pinned FreeType source before retained-asset selection.
Source packages carry `MADEIRA-NATIVE-SOURCES.json` so the same file inventory is
available without Git; actual working bytes, including applied replacement
patches, are hashed without reverting or normalizing source edits. Older source
packages lacking this inventory cannot validate a new native receipt.

Each run saves its full log under `.build/local-build-logs/` and prints the path.
The output folder contains `Iridium-unsigned.ipa`, `SHA256SUMS`, and
`ipa-signature-audit.json`. The package needs recipient signing before install.
Its anonymous memory-limit carrier does not grant a provisioning entitlement.
