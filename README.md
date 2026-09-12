# Iridium

An experimental iPhone and iPad Windows-game runtime, with a native game library and touch, keyboard, mouse, and controller integration. Compatibility varies by game and device.

This monorepo contains Iridium, its runtime forks, and the Madeira runtime source used by the current integration. Game files must be supplied by the user.

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

## Privacy and contributions

Run `python3 check-public-source.py` before contributing. You can pass private strings as arguments for a targeted local scan; do not add those strings to public workflows. This scan does not guarantee anonymity.

Do not commit signing certificates, private keys, provisioning profiles, pairing records, personal device logs, build outputs, or game assets. Required upstream author credits remain intact.

## Project standards

Read [CONTRIBUTING.md](CONTRIBUTING.md) for implementation, review, validation,
privacy, and dependency rules. Follow [the release policy](docs/releasing.md)
and its fixed description template for every release. Builds remain manual.
