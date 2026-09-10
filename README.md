# Iridium

An experimental iPhone and iPad Windows-game runtime, with a native game library and touch, keyboard, mouse, and controller integration. Compatibility varies by game and device.

This monorepo contains Iridium, its runtime forks, and the Madeira runtime source used by the current integration. It is a source release. No IPA, game files, signing credentials, or prebuilt runtime bundle is included.

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

The existing build scripts are included, but currently depend on locally staged runtime and media libraries. A clean-runner IPA build is not verified yet. See [the Actions plan](docs/actions-ipa.md). Historical documents under the component directories may describe older runtime states.

## Privacy and contributions

Run `python3 check-public-source.py` before contributing. You can pass private strings as arguments for a targeted local scan; do not add those strings to public workflows. This scan does not guarantee anonymity.

Do not commit signing certificates, private keys, provisioning profiles, pairing records, personal device logs, build outputs, or game assets. Required upstream author credits remain intact.
