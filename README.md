# Iridium

Iridium is an iPhone and iPad game launcher with Windows support through
[Madeira](https://github.com/willfaust/Madeira) and console emulation through
SameBoy, PPSSPP, Dolphin, Azahar, Play!, and Flycast.

It provides a shared library, artwork, touch controls, controller and keyboard
input, stores, and per-game settings. Stores include Steam, GOG, Epic Games, EA,
and itch.io. Compatibility varies by game and device. Each engine needs its own
device tests for graphics, input, audio, saves, and repeated launches.

The current development version is **0.3.0**. See its
[review notes](docs/releases/0.3.0.md) for changes and limits. This version is not
a published release. Menu sound effects remain in a separate draft PR.

## Install

Download the IPA from [Releases](https://github.com/intraducine/iridium/releases).
Sign the app and its extensions with a compatible sideloading tool, or use
LiveContainer. Supply your own game files.

In AltStore or LiveContainer, add the [Stable source](https://raw.githubusercontent.com/intraducine/iridium/main/altstore/stable.json)
for published releases or the [Nightly source](https://raw.githubusercontent.com/intraducine/iridium/altstore-nightly/altstore/nightly.json)
for selected builds from `main`. Both channels use the same app ID. Choose one
channel for updates. Nightly becomes available after the first Nightly build.

The app requires iOS/iPadOS 18 or later. JIT requirements depend on the engine
and installation method; see [JIT setup](iridium/docs/builtin-stikjit-ios27.md).
Back up saves before updating and keep the existing app data.

Use **Add Game → Files and Folders** for games, archives, or pairing files.
`Documents/Import` also accepts bulk imports. Managed game folders use
`Documents/Games`; see [Using Iridium](iridium/docs/product-experience.md).

## Build

For Windows, GB/GBC, and PSP, use an Apple Silicon Mac with Xcode 27,
Homebrew, Python 3.11+, and Rust:

```sh
git clone https://github.com/intraducine/iridium.git
cd iridium
bash ci/build-madeira-ipa.sh
```

For Dolphin, Azahar, Play!, and Flycast, continue with the
[console build steps](docs/console-engines.md#build-and-replace).
The [build guide](docs/actions-ipa.md) also covers manual Actions builds and
library replacement.

## Documentation

- [Using Iridium](iridium/docs/product-experience.md)
- [0.3.0 review notes](docs/releases/0.3.0.md)
- [Runtime integration](docs/runtime-integration.md)
- [Console engines](docs/console-engines.md)
- [Contributing](CONTRIBUTING.md)
- [Release process](docs/releasing.md)

Original Iridium code is AGPL-3.0-only. Third-party components keep their own
licenses. See [LICENSING.md](LICENSING.md) and [upstream changes](CHANGES-FROM-UPSTREAM.md).
