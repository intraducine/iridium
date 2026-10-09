# Iridium

![iOS](https://img.shields.io/badge/iOS-supported-black?style=flat-square&logo=apple)
![Release](https://img.shields.io/github/v/release/intraducine/iridium?style=flat-square)
![Downloads](https://img.shields.io/github/downloads/intraducine/iridium/total?style=flat-square)
![License](https://img.shields.io/github/license/intraducine/iridium?style=flat-square)

Iridium is an iPhone and iPad frontend for [Madeira](https://github.com/willfaust/Madeira).
Its library, game options, settings, Steam pages, setup, and player menus share
Iridium's artwork and Apple-style navigation. Madeira provides game launch,
JIT, input, Steam, downloads, saves, and the runtime. Compatibility varies by
game and device.

Use **Add Game → Steam Library** for Madeira's Steam features. For local files,
copy the game folder into **Iridium → wine → drive_c** in Files, then use
**Add Game → Choose Executable**. Existing Iridium libraries can be copied with
**Add Game → Import Existing Iridium Games**. Original folders and saves stay
in place. A conflicting save stops import instead of overwriting either copy.

| Directory | Purpose |
| --- | --- |
| `vendor/Madeira/` | Pinned Madeira app and its dependency submodules |
| `iridium/apps/ios/MadeiraFrontend/` | Iridium presentation and data import |
| `ci/madeira-frontend.py`, `ci/madeira_presentation.py` | Reviewed presentation overlay and native build preparation |
| Other runtime and application directories | Retained migration and recovery source; excluded from the frontend target |

Original Iridium code is **AGPL-3.0-only**. Third-party code retains its own licenses. Read [LICENSING.md](LICENSING.md) before redistributing. Madeira is credited for the runtime approach and implementation.

## Getting the source

Clone this repository. The frontend builder initializes the required Madeira
submodules at their committed revisions. It does not initialize FEX's large test
repositories. The current pin is recorded in [UPSTREAM-SOURCES.json](UPSTREAM-SOURCES.json).
Upstream updates require a pin update and review of the declared hooks.

## Build a sideloading IPA locally

Use an Apple Silicon Mac, Xcode 27 with the Metal tools, Python 3.11 or newer,
Homebrew, and Rust. Run this command from the repository root:

```sh
bash ci/build-madeira-ipa.sh
```

The script prepares Madeira's native libraries, builds its app with the Iridium
presentation, checks the package, and prints the path to `Iridium-unsigned.ipa`.
The configuration is Debug, as used by Madeira's guest-runtime build. The
package tool strips debug sections from the delivered copy. Native outputs are
saved before packaging and reused for up to 14 days when their inputs and
archive checks match. Xcode also keeps its incremental app build.

The main app targets iOS 18 and later. The built-in JIT helper requires iOS 26
or later; use external JIT on earlier versions. See the
[build guide](docs/actions-ipa.md) for local and GitHub Actions commands.

Packaging adds an anonymous ad-hoc signature to the main executable carrying
only `com.apple.developer.kernel.increased-memory-limit=true`; helpers remain
unsigned. The existing filename is retained for download compatibility.
Re-sign the app and sign its helper extensions with a suitable sideloading tool
before installation.

## Privacy and contributions

Run `python3 check-public-source.py` before contributing. You can pass private strings as arguments for a targeted local scan; do not add those strings to public workflows. This scan does not guarantee anonymity.

Do not commit signing certificates, private keys, provisioning profiles, pairing records, personal device logs, build outputs, or game assets. Required upstream author credits remain intact.

## Project standards

Read [CONTRIBUTING.md](CONTRIBUTING.md) for implementation, review, validation,
privacy, and dependency rules. Follow [the release policy](docs/releasing.md)
and its fixed description template for every release. Builds remain manual.
