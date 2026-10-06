# Iridium

![iOS](https://img.shields.io/badge/iOS-supported-black?style=flat-square&logo=apple)
![Release](https://img.shields.io/github/v/release/intraducine/iridium?style=flat-square)
![Downloads](https://img.shields.io/github/downloads/intraducine/iridium/total?style=flat-square)
![License](https://img.shields.io/github/license/intraducine/iridium?style=flat-square)

An experimental iPhone and iPad Windows-game runtime, with a native game library and touch, keyboard, mouse, and controller integration. Compatibility varies by game and device.

This monorepo contains Iridium, its runtime forks, and the Madeira runtime source used by the current integration. Import your game files or use **Add Game → Download from Steam** to sign in and download owned games directly on the device. The [Steam integration](iridium/packages/steam/README.md) has passed iOS compilation and limited simulator checks. Real-account authentication, downloads, and physical-device validation remain outstanding; game compatibility and Iridium's JIT requirements apply.

The consolidated [0.2.1 preparation](docs/releases/0.2.1.md) includes opt-in Steam
Cloud, standalone background downloads, a download Live Activity, editable
launch arguments, controller improvements and a global sync selector under
**Settings → Runtime**. A fresh consolidated build and device validation remain
pending; existing Actions builds do not establish these changes work on-device.

| Directory | Purpose |
| --- | --- |
| `iridium/` | iOS application, Swift packages, integration, and tests |
| `iridium-runtime-sdk/` | Runtime host SDK |
| `iridium-fex-ios/` | Earlier Iridium FEX fork |
| `iridium-wine-ios/` | Earlier Iridium Wine fork |
| `testrepos/Madeira/` | Madeira integration source and its FEX, Wine, and DXMT forks |

Original Iridium code is **AGPL-3.0-only**. Third-party code retains its own licenses. Read [LICENSING.md](LICENSING.md) before redistributing. Madeira is credited for the runtime approach and implementation.

## Getting the source

Clone this repository. Optional external dependencies are pinned in the root `.gitmodules` and `DEPENDENCIES.json`; use `git submodule update --init --recursive` when preparing them. Some optional upstream test dependencies contain binaries; they are not stored in this repository.

The [manual IPA workflow](docs/actions-ipa.md) builds runtime dependencies and the app, with source and license checks before packaging. IPA packaging requires the final binary and source audits to pass. Start with the [product guide](iridium/docs/product-experience.md) for app navigation and the build guide for development setup.

## Build a sideloading IPA locally

Install Xcode 27, Python 3.12 or newer, XcodeGen, LLVM, and .NET SDK 10.0.401. Prepare the runtime
dependencies by following [the full IPA build guide](docs/actions-ipa.md), then
run this command from the repository root:

```sh
bash ci/build-local-ipa.sh
```

The script checks the staged dependencies, builds the Release app without
Apple signing, audits the package, and prints the path to `Iridium-unsigned.ipa`.
Packaging adds an anonymous ad-hoc signature to the main executable carrying
only `com.apple.developer.kernel.increased-memory-limit=true`; helpers remain
unsigned. The existing filename is retained for download compatibility.
It keeps `.build/local-ipa`, so later builds reuse unchanged Xcode outputs.
Re-sign the app and sign its helper extensions with a suitable sideloading tool
before installation.

## Privacy and contributions

Run `python3 check-public-source.py` before contributing. You can pass private strings as arguments for a targeted local scan; do not add those strings to public workflows. This scan does not guarantee anonymity.

Do not commit signing certificates, private keys, provisioning profiles, pairing records, personal device logs, build outputs, or game assets. Required upstream author credits remain intact.

## Project standards

Read [CONTRIBUTING.md](CONTRIBUTING.md) for implementation, review, validation,
privacy, and dependency rules. Follow [the release policy](docs/releasing.md)
and its fixed description template for every release. Builds remain manual.
