# Console engines

Standard Actions IPA builds include all integrated engines. Pins are in
[UPSTREAM-SOURCES.json](../UPSTREAM-SOURCES.json).

| Engine | System | Build entry | Limits |
| --- | --- | --- | --- |
| SameBoy 1.0.4 | GB/GBC | `ci/build-sameboy.py` | Interpreter; replacement boot ROMs |
| PPSSPP 1.20.4 | PSP | `ci/build-ppsspp-native.py` | Optional JIT with interpreter fallback |
| DolphiniOS 5.0.0b6 | GameCube/Wii | `ci/build-phase3.py --engine dolphin` | Shared JIT required; no interpreter fallback |
| Azahar 2126.2 | 3DS | `ci/build-phase3.py --engine azahar` | Shared JIT required; layouts and screen swapping use core settings |
| Play! 0.77 | PS2 | `ci/build-phase3.py --engine play` | Shared JIT; bounded VM pause before teardown; repeated launch needs device validation |
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
| 3DS | `.3dsx`, `.3ds`, `.cci`, `.cxi`, `.app` | Prepared files; CIA games, updates and DLC install through Add Game or Emulator Files |
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
stick click. Bluetooth Wii Remotes are unsupported. Azahar maps touch through its
selected screen layout and rejects taps outside its touchscreen. The shared host
supplies phone motion to Azahar's sensor interface; device orientation and motion
calibration still need physical-device validation.

## In-game controls

Core Settings lists the selected engine's supported choices. Values are saved per
game for SameBoy and the Libretro engines. PPSSPP retains its upstream config
file and applies live changes on its render thread. PSP Model and Software
Rendering are saved per game in Iridium and applied before the next native CPU/GPU
initialization. These two controls do not change the running engine. Dolphin applies typed
upstream configuration fields. Graphics backends and required JIT settings stay
under the engine adapters' control. Settings which the core reads only at startup
take effect after the game closes and opens again.

SameBoy, Azahar, Play!, and Flycast now have five state slots in the shared menu.
PSP and Dolphin keep their existing state interfaces. State files are separate
from ordinary in-game saves. Loading captures a rollback state first; a failed
rollback retains the runtime lease and requires an app restart. State files are
bounded and tied to the engine version. Compatibility across engine updates is
not guaranteed.

SameBoy also has 2× speed, with game audio muted, and optional rewind history
limited to 32 MB. Rewind records a state every six frames. The menu can move back
up to thirty recorded states, with less history available when states are large.

The shared host polls separate controller slots for Play! (two players) and
Flycast (four players). Play!'s generated input adapter also polls both ports.
Supported physical controllers receive the shared host's game vibration. Strong
and weak motor values are combined into the controller's available haptic output.
Pause, disconnect, and stop cancel that output. Phone and menu haptics stay separate.

The game menu includes a per-game cheat editor for SameBoy (GameShark and Game
Genie), PPSSPP (CWCheat), Dolphin (Gecko and Action Replay), and Azahar (Gateway).
Code sets are bounded and validated before replacing Iridium's active set.
Invalid edits keep the previous set. PPSSPP's existing cheat INI files and
Dolphin/Azahar's existing codes are preserved. Iridium stores its own named,
enabled/disabled entries per game and reapplies them on launch. Codes must match
the game version; compilation is not evidence that a particular code works.

### Content, discs, and peripherals

Open a game's library options, then **Emulator Files**. PSP exposes its game's
texture folder, shaders and cheat files. Dolphin exposes its game's textures,
Game INI patches and shaders. Select an extracted folder or file to import; ZIP,
7z and RAR packages must be extracted first. Imports merge into a private copy
before replacing the destination. The previous directory remains in Content
Backups and can be exported from the same page. Sources are copied, not removed.
Imports reject links, special files and conflicting case-insensitive names, and
are bounded to 100,000 entries and 64 GiB. Close all games before importing.
Enable the corresponding texture option in Core Settings after import.

Dolphin's **Game Patches** editor supports built-in patch toggles and named local
patches. Built-in code cannot be overwritten; give an edited copy a new name.
The editor preserves unrelated Game INI sections and restores app-managed cheats
after upstream patch reload. **Change Disc** selects another imported game-disc
image without replacing the current session. Play! mounts it on the paused VM
thread and restores the old disc on insertion failure. Flycast also retains its
registered disc list and restores the previous path and tray state if insertion
fails. Failed recovery keeps the runtime lease and requires an app restart. Disc changes do not create or replace a save-state slot.

For the first 3DS game, choose **Install 3DS CIA** from Add Game and use new
storage. Select an existing game's storage for updates or DLC. Emulator Files
also has **Install CIA Game, Update, or DLC**. Azahar installs into a staged copy
of the selected storage. New storage accepts a base game only. Base games
receive library entries which share that storage; updates and DLC remain with
their base title. Each installed title keeps separate state slots within the
shared storage. Publication retains a backup. This installer accepts unencrypted
CIA files only. A failed library-entry write leaves
the installed content and backup intact and reports the error.

Azahar's Core Settings includes **Phone Camera** (off, rear, front) and **Phone
Microphone**. For microphone input, also select the core's Frontend input mode.
Both inputs default to off. iOS asks for access only after the option is enabled
and the game requests capture. Pause and close stop capture. One selected phone
camera supplies the virtual camera views; stereo depth is not supplied. Motion
uses the existing sensor interface. Capture timing, orientation and game behavior
still need device tests.

PSP multiplayer settings include networking, the local ad hoc server, server
address, UPnP, channel, port offset, timeout and first-connect policy. Use matching
settings and game versions on peers, reopen the game and enter its multiplayer
mode. A local host enables its ad hoc server and uses 127.0.0.1; peers use the
host's local IP address. Flycast builds its pinned UPnP dependency and exposes
network/Broadband Adapter options. Supported games still need their own network
configuration and, where required, an external server. No peer match has been
verified in this change.

Flycast exposes supported controller types per port and upstream VMU/rumble slot
options. Emulator Files exports and imports VMU/arcade save files with their
original names. Keyboard, light-gun and motion-only peripherals are not exposed
without a matching host input implementation. Real Wii Remotes remain unsupported
by iOS; ordinary supported game controllers use the existing emulated controls.

The shared OpenGL display copy now restores the core's framebuffer, renderbuffer,
scissor and clear-color state, including failed presentation. This fixes a host
state leak that can affect Play! rendering. GTA's PS2 shading fault has not been
retested; the source fix does not establish its cause or visual result.

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

Play! drains remaining graphics commands after VM pause, before state capture or
the single GS release during teardown. A
Windows host initializes once per app process. The Madeira adapter starts each game
as a separate Windows job through an owned, versioned session launcher. A completed
job must have no remaining native threads before admission returns to the library.
Stale status and close requests carry a different launch token and cannot finish or
stop the current game. A failed or uncertain drain retains ownership and requires
an app restart. Closing a game never initializes Wine or wineserver again.

Shared JIT preparation creates the retained Windows arena and the reusable console
arena during one owned built-in-helper activation. Later games reuse these arenas;
they do not enable JIT again. The Windows host remains resident while console games
run. This retains its memory and services, so a passing build alone does not establish
phone memory use, power use, performance, or graphics compatibility. Windows
configuration read only during host initialization still applies to the host lifetime.
The launcher and its source receipt belong to the Madeira adapter. Updating a runtime
pin rebuilds the matching adapter without moving Wine lifecycle details into the
shared library or the other emulator adapters.

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
