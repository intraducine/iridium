# Console engines

Standard Actions IPA builds include all integrated engines. Pins are in
[UPSTREAM-SOURCES.json](../UPSTREAM-SOURCES.json) and the component recipes.

| Engine | System | Build entry | Limits |
| --- | --- | --- | --- |
| SameBoy 1.0.4 | GB/GBC | `ci/build-sameboy.py` | Interpreter; replacement boot ROMs |
| PPSSPP 1.20.4 | PSP | `ci/build-ppsspp-native.py` | Optional JIT with interpreter fallback |
| DolphiniOS 5.0.0b6 | GameCube/Wii | `ci/build-phase3.py --engine dolphin` | Shared JIT required; no interpreter fallback |
| Azahar 2126.2 | 3DS | `ci/build-phase3.py --engine azahar` | Shared JIT required; fixed stacked-screen layout |
| Play! 0.77 | PS2 | `ci/build-phase3.py --engine play` | Own JIT probe; restart after a session; device unverified |
| Flycast 2.7 | Dreamcast/arcade | `ci/build-phase3.py --engine flycast` | Own JIT probe; device unverified; upstream dropped supported iOS distribution |

Dolphin uses upstream Metal and CoreAudio. Azahar uses its main Vulkan renderer
through source-built MoltenVK 1.4.1. PSP has its own MoltenVK 1.2.9 source inputs.
Dolphin and Azahar cannot pass the required JIT probes on Simulator.

## Import and storage

Use **Add Game → Choose Files**. Select the containing folder for GDI/CUE games
so all referenced tracks are available. Ambiguous formats ask for a system.

| System | Files | Restrictions |
| --- | --- | --- |
| GB/GBC | `.gb`, `.gbc` | Uncompressed cartridge images |
| PSP | `.elf`, `.iso`, `.cso`, `.pbp` | Supported PSP headers |
| GameCube/Wii | `.dol`, `.gcm`, `.iso`, `.rvz`, `.wad` | WAD installation needs a stopped session and backup |
| 3DS | `.3dsx`, `.3ds`, `.cci`, `.cxi`, `.app` | Prepared, unencrypted files; no CIA installer |
| PS2 | `.elf`, `.iso`, `.chd`, `.cue` | CUE requires one track per binary file; known PS1 discs rejected |
| Dreamcast | `.elf`, `.cdi`, `.chd`, `.gdi`, `.cue` | Include all referenced tracks |
| Arcade | `.zip` | Standalone flat sets; no encrypted entries, links, or archive comments |

Game copies use `Documents/IridiumRuntimes/Games/<UUID>`, saves use
`Saves/<runtime>/<UUID>`, and system data uses `System/<runtime>`. Azahar adds
`Azahar` below its save root; Flycast uses `dc` below its system root. Dolphin
bundles upstream `Sys` and stores NAND/cards/configuration with the game saves.
The build supplies no commercial games, console keys, or proprietary BIOS files.

Shared controls include touch, keyboard, and up to four controllers. GameCube Z
maps to RB. Wii minus/plus map to Select/Start, 1/2 to Y/X, Nunchuk C/Z to L/R,
and shake to L2. IR uses the right stick or display touch. Wii Home uses the left
stick click. Bluetooth Wii Remotes are unsupported. 3DS touch targets the lower
320×240 screen; the layout is not selectable.

## Lifecycle and JIT

Madeira, PSP, Dolphin, and Azahar share `JITCoordinator`. Each engine retains its
own allocation and execution checks. Dolphin/Azahar require live attachment for
new executable memory. Their shared helper must finish, detach, clear the live
debugger flag, and restore networking before the next launch. Unknown attachment
or uncertain cleanup requires restart. PSP retains its separate prepared-arena
and teardown checks.

The shared menu owns pause, resume, controls, and close. A runtime lease is
released only after confirmed teardown. Play!/Flycast also pause their upstream
VM threads. Libraries remain loaded after stop.

## Build and replace

Use the [build prerequisites](actions-ipa.md), then:

```sh
git submodule update --init --recursive vendor/Dolphin vendor/Play vendor/Flycast
git submodule update --init vendor/Azahar
mkdir -p .build/phase3-downloads
gh release download 2126.2 --repo azahar-emu/azahar \
  --pattern azahar-libretro-ios-arm64-2126.2.zip \
  --pattern azahar-unified-source-2126.2.tar.xz \
  --dir .build/phase3-downloads
python3 ci/build-phase3.py --engine all --sdk iphoneos --jobs 3
IRIDIUM_PHASE3=1 python3 ci/madeira-frontend.py app --reuse-psp-component
IRIDIUM_PHASE3=1 python3 ci/madeira-frontend.py check-bundle \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app
```

Select one engine instead of `all` to rebuild it alone. Use `--sdk iphonesimulator`
for compile checks. [Package the app](actions-ipa.md) after rebuilding.
Receipts check source/dependency pins, recipes, generated adapters, ABI, exports,
platform, binaries, and resources. Changed interfaces require matching host and
engine builds. Preserve dependency notices and matching source.

SameBoy can be built directly:

```sh
python3 ci/build-sameboy.py --sdk iphoneos --target arm64-apple-ios18.0 --output .build/sameboy/iphoneos
```

Its replacement boot data is locked in `ci/sameboy-bootroms.json`. Reproduce it
with RGBDS 0.9.4 from `gbdev/rgbds` commit
`d1829ed92327a9f9210ffd45d865331f24dfa4e6`, then run
`python3 ci/sameboy_bootroms.py --rgbds /path/to/rgbds --output /tmp/bootroms.json`
and compare the output with the tracked file.

## Validation

Use the [device checklist](../iridium/docs/manual-validation-runbook.md). For each
engine, verify frames, input, audio, saves, background/resume, close, and a second
launch. An allocator probe or successful build does not establish gameplay.
[LICENSING.md](../LICENSING.md) records distribution limits.
