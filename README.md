# Iridium

Play Windows and console games on iPhone and iPad. Import games you own into one
library and play with touch controls, a controller, or a keyboard.

## Install

Requires iOS or iPadOS 18 or later.

- **Stable** is the regular release. [Download the Stable IPA](https://github.com/intraducine/iridium/releases/latest/download/Iridium-unsigned.ipa) · [Stable AltStore source](https://raw.githubusercontent.com/intraducine/iridium/main/altstore/stable.json)
- **Nightly** builds are for trying recent changes. [Nightly downloads](https://github.com/intraducine/iridium/releases?q=nightly-) · [Nightly AltStore source](iridium/docs/product-experience.md#nightly-altstore-source)

To install through AltStore Classic or LiveContainer, copy the AltStore source
URL into **Sources**. You can also download the IPA and install it manually.

## Supported systems

Stable supports Windows games. Full builds from `main` also support the consoles and
arcade systems below. Game compatibility varies. Windows games and many console
games require [JIT setup](iridium/docs/builtin-stikjit-ios27.md).

| System | Powered by |
| --- | --- |
| Windows | [Madeira](https://github.com/willfaust/Madeira) |
| Game Boy and Game Boy Color | [SameBoy](https://github.com/LIJI32/SameBoy) |
| PSP | [PPSSPP](https://github.com/hrydgard/ppsspp) |
| GameCube and Wii | [DolphiniOS](https://github.com/OatmealDome/dolphin-ios) |
| Nintendo 3DS | [Azahar](https://github.com/azahar-emu/azahar) |
| PlayStation 2 | [Play!](https://github.com/jpd002/Play-) |
| Dreamcast and supported arcade systems | [Flycast](https://github.com/flyinghead/flycast) |

## Guides

- [Using Iridium](iridium/docs/product-experience.md)
- [Supported console file formats](docs/console-engines.md#import-and-storage)
- [Release notes](https://github.com/intraducine/iridium/releases)

## Source code

[Browse the source on main](https://github.com/intraducine/iridium/tree/main).
For the source used to build a specific IPA, download the source archive from
that release’s **Assets**. [Stable release](https://github.com/intraducine/iridium/releases/latest) · [Nightly releases](https://github.com/intraducine/iridium/releases?q=nightly-)

## Development

- [Build an IPA](docs/actions-ipa.md)
- [Runtime integration](docs/runtime-integration.md)
- [Contributing](CONTRIBUTING.md)

Iridium’s own code is AGPL-3.0-only. See [licenses](LICENSING.md) for
third-party components.
