# Iridium

Play Windows and console games on iPhone and iPad. Import games you own into one
library and play with touch controls, a controller, or a keyboard.

## Install

Requires iOS or iPadOS 18 or later.

- **Stable:** [Download IPA](https://github.com/intraducine/iridium/releases/latest/download/Iridium-unsigned.ipa) · [Install feed](https://raw.githubusercontent.com/intraducine/iridium/main/altstore/stable.json) · [Matching source](https://github.com/intraducine/iridium/releases/latest)
- **Nightly:** [Builds and matching source](https://github.com/intraducine/iridium/releases?q=nightly-) · [Install feed URL](iridium/docs/product-experience.md#nightly)

Add the install feed in AltStore Classic, or install the IPA with a compatible
sideloading tool or LiveContainer. Windows games and many console games need
[JIT setup](iridium/docs/builtin-stikjit-ios27.md).

## Guides

- [Using Iridium](iridium/docs/product-experience.md)
- [Supported console file formats](docs/console-engines.md#import-and-storage)
- [Release notes](https://github.com/intraducine/iridium/releases)

## Development

- [Browse the source on main](https://github.com/intraducine/iridium/tree/main)
- [Build an IPA](docs/actions-ipa.md)
- [Runtime integration](docs/runtime-integration.md)
- [Contributing](CONTRIBUTING.md)

Iridium’s own code is AGPL-3.0-only. The Windows runtime uses
[Madeira](https://github.com/willfaust/Madeira). See [licenses](LICENSING.md) for
third-party components.
