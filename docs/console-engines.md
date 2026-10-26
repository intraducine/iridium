# Console engines

Standard Actions IPA builds include all integrated engines. Pins are in
[UPSTREAM-SOURCES.json](../UPSTREAM-SOURCES.json).

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

Game copies use `Documents/Games/<game title> - <UUID>`. Names exclude unsafe path
characters. The UUID keeps same-title games separate. Existing game folders move there on
first use without changing library IDs or saves. Saves use
`Documents/IridiumRuntimes/Saves/<runtime>/<UUID>`, and system data uses
`Documents/IridiumRuntimes/System/<runtime>`. Azahar adds
`Azahar` below its save root; Flycast uses `dc` below its system root. Dolphin
bundles upstream `Sys` and stores NAND/cards/configuration with the game saves.
The build supplies no commercial games, console keys, or proprietary BIOS files.

`Documents/Import` accepts game files, complete game folders, pairing files, and
bulk ZIP/7z archives. It runs while the app is active and no game or Steam download
is running. Add Game > Import Folder shows choices, errors, remaining files, and
Retry Import. Choose Files adds every selected input to the same queue; copies
outside Iridium remain untouched. This layout uses the host's Documents folder
in both standalone installs and LiveContainer.

A source leaves Import only after its game record or validated Keychain pairing
is stored. Interrupted imports reuse their recorded IDs. Ambiguous systems,
multiple executables, and multiple pairing files need a choice. Unsupported,
incomplete, encrypted, or failed inputs stay available for repair or retry.
Completed imports remove empty staging folders. Other files, including hidden
files, remain in Import. Stable relative aliases keep Windows and Steam paths
working when a managed game folder is renamed. A Steam manifest alone does not
make a missing or empty game folder ready to play; the library offers Repair.
Steam records used only for shared content do not create extra game cards.
Remove from Library keeps files and saves. Steam removals keep settings and stay
hidden across scans and restarts. Add to Library in the game's Steam options
restores the card. Uninstall removes a managed Steam game's files and install
record, even if either is already missing. Its confirmation warns that saves
inside the game folder are removed too; saves elsewhere stay on the device.
Archive extraction rejects links and paths that escape its new staging folder,
limits entries and expanded bytes, and publishes only complete extractions.
Unrecognized files from an archive stay in its extracted folder.

Windows installations also move to Games. A recorded relative link retains each
old C: path, including Steam's installation paths. Entries that share one physical
installation keep that one folder. Wine, the Steam client, saves, and runtime
system files retain their own storage. A loose executable in the C: root moves by itself and retains its old path;
unrelated files on the Windows drive stay in place.

Older builds do not understand the new game root. Before downgrading, back up
Documents. Move console folders from Games back to IridiumRuntimes/Games using
the same UUIDs. For Windows, `.iridium-game-moves.json` records each original
path relative to wine/drive_c and its Games UUID. Replace only that recorded
installation link with its matching game folder. Keep library files, saves,
system data, and unrelated links intact. Do not combine or overwrite conflicting
folders.

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

## Update one engine

`UPSTREAM-SOURCES.json` selects the Madeira, SameBoy, PPSSPP, Dolphin, Azahar,
Play! and Flycast revisions. It also selects the engine-specific MoltenVK
versions, Azahar release archives, RGBDS build tool and Madeira FreeType revision.
Builders, packaging checks and source collection read these pins through
`ci/engine_pins.py`. The submodule gitlinks remain the checkout lock and must
match the selected revisions.

To update one engine:

1. Update its entry in `UPSTREAM-SOURCES.json` and its submodule gitlink. For a
   fork, also update the matching URL in `.gitmodules`.
2. Review its adapter against that source. Phase 3 overlays and target rules
   live in `ci/phase3_<engine>.py` and `ci/<engine>-targets.cmake`. PPSSPP and
   SameBoy retain their separate builders. Shared JIT stays in the app service;
   an engine adapter must use its existing callback and ownership contract.
3. Update the selected dependency source manifests when dependencies change.
   Regenerate affected atlas/boot-ROM records and review API contracts and
   license records. Those records describe audited inputs; they do not select
   a second engine version and must not be relabelled without verification.
4. Stage the matching submodule gitlink, then run `python3 ci/engine_pins.py`.
   Run the repository source checks and build the changed component. Run device
   tests for rendering, input, saves, pause/resume, JIT cleanup and another launch.

Saved compilation is checked against only the selected engine's pin and its
own adapter files, plus shared compiler inputs. A change to one engine pin or
adapter does not invalidate other engines. The shared host consumes Flycast's
libretro header, so a Flycast pin change also invalidates that host. Changes to
shared build code or interfaces still invalidate their consumers. Different
MoltenVK versions remain in separate engine outputs. A version change is a
build-time selection and still needs a compatible adapter and a new app package.

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
