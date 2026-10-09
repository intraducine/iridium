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

Each run saves its full log under `.build/local-build-logs/` and prints the path.
The output folder contains `Iridium-unsigned.ipa`, `SHA256SUMS`, and
`ipa-signature-audit.json`. The package needs recipient signing before install.
Its anonymous memory-limit carrier does not grant a provisioning entitlement.
