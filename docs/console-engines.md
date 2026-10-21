# Console engine builds and verification

Dolphin, Azahar, Play!, and Flycast are included in standard Actions IPA builds.
Physical-device verification is pending for all four. A compiled component, imported game,
opened player, or allocator probe is not a successful game launch. The UI waits
for an upstream video callback and reports failures without simulating playback.

## Pinned implementations

| Engine | Selected source | Adapter policy |
| --- | --- | --- |
| Dolphin, GameCube/Wii | DolphiniOS `v5.0.0b6`, `7cac54161659421ed95c2cd1c0b0746539a4cd38` | Upstream core, host queue, Metal, CoreAudio and iOS input profiles. CPU interpreter, HLE DSP without DSP JIT, software vertex loader. |
| Azahar, Nintendo 3DS | Official `2126.2`, `219d743a1e698101fe1ab8bef43e6563126c3c27` | Digest-verified official iOS Libretro binary and matching unified source. CPU/shader interpreters and software graphics. Simulator core built from that source. |
| Play!, PlayStation 2 | Official `0.77`, `fa75cea31a33f5ab7a2008ed0d90dc74353e9cef` | Upstream Libretro VM, OpenGL ES GS and CodeGen. Its own executable-memory probe is required. Restart after a session because configuration uses a process singleton. |
| Flycast, Dreamcast/arcade | Official `v2.7`, `5aa091fde632fb332c8d8c34e280d62dc951954c` | Upstream Libretro runtime and ES3 renderer. Device requires its own executable-memory probe; simulator recompilers are compiled out upstream. This release dropped supported iOS distribution; the adapter remains device unverified. |

Dolphin's selected iOS port is a beta. The plain interpreter avoids a reproduced
cached-interpreter shutdown allocator crash in that port; current-run settings
prevent game INI files from selecting JIT. Its interpreter and Azahar's software
renderer can be too slow for a game. Play!/Flycast may remain unavailable when
iOS rejects their upstream allocators. Helper readiness is only a prerequisite;
the allocator must execute 42, rewrite the block, then execute 7. That small
check does not establish later arena sizes or guest JIT behavior. No PSP
prepared arenas, BetterJIT experiments, new helper opcodes, exception-port
repair, or replacement emulator internals are used.

The Dolphin platform overlay disables framebuffer fetch only on Simulator:
its advertised Apple GPU family otherwise selects shaders that Simulator Metal
rejects as unsupported render-target reads. Device capability detection and
the upstream non-fetch shader fallback remain intact.

The shared Iridium menu, pause/resume, touch editor, opacity, keyboard, physical
controller and ownership rules remain app owned. Cores use separate dynamic
images with private C APIs, retained after stop. Ownership is released only
after upstream unload/deinit and audio/video cleanup return. Partial init/load
exceptions or uncertain shutdown retain the lease and require restart. Windows
continues to require restart before another runtime.

Pause stops the libretro frame pump and explicitly pauses the independently
running Play!/Flycast VMs through upstream methods. Play! pumps the GS mailbox
while waiting for its asynchronous pause; it keeps renderer resources intact.
Flycast's stop path joins its execution thread and flushes nonvolatile storage
before resume starts it again. Audio interruptions use this same transition.
Azahar touch is restricted to the lower 320×240 screen within its selected
400×480 top-bottom canvas; touches on the top screen or bars release the stylus.
This build fixes that layout and does not forward Azahar's L3 screen-swap hotkey;
other engines retain thumb clicks. A selectable 3DS layout is not yet exposed.

## Inputs and user-supplied files

Add Game → Choose Files accepts game files or a complete game folder. Headers
identify the system whenever possible: ELF architecture/flags, cartridge and
disc signatures, and RVZ's uncompressed disc header. Unknown MIPS executables,
DOL and CHD require a system choice. PlayStation discs use SYSTEM.CNF BOOT2 to
identify PS2; known PS1 ISOs are rejected, and unidentified PLAYSTATION ISO/CUE
files require confirmation. ZIPs ask before treating a set as arcade content;
Windows archives should be extracted into a game folder.

GDI/CUE imports retain the manifest and its named tracks with their relative
paths. Choose the containing folder or select all files together. Import reads
and copies each concrete file under coordinated access, checks names and
symlinks, and revalidates the private copy before registering it. A missing or
unsupported track layout produces a contextual action rather than demanding
conversion of every disc. Mixed selections retain readable candidates and
report rejected files. Existing records and saves are retained.

Settings has one shared Launch Support destination. Per-system and per-game
pages link directly to setup when needed. Consumer screens omit development
status and allocator details; engineering evidence remains in logs and this
acceptance document.
Use games/firmware you are entitled to use. The build downloads no games or
console BIOS. Bounded structural validation does not establish compatibility
or decrypt content.

| System | Imports | Limits |
| --- | --- | --- |
| GameCube/Wii | `.dol`, `.gcm`, `.iso`, `.rvz` | Choose the system for DOL; ISO/RVZ use disc headers. No WAD installation, real Wiimote, motion/gyro or NAND-management UI. |
| Nintendo 3DS | `.3dsx`, `.3ds`, `.cci`, `.cxi`, `.app` | Prepared unencrypted single files/homebrew. `.3ds` and `.cci` use the same NCSD checks. No CIA installer or encrypted-game preparation. Upstream top/bottom display layout and lower-screen touch mapping. |
| PlayStation 2 | `.elf`, `.iso`, `.chd`, `.cue` | R5900 ELF flags identify PS2; ISO uses PLAYSTATION. Choose PS2 for CHD. Play! supplies its own high-level system implementation. Its CUE reader requires one track per binary file; unsupported shared-track layouts are rejected before launch. |
| Dreamcast | `.elf`, `.cdi`, `.chd`, `.gdi`, `.cue` | SH ELF/CDI/GDI identify Dreamcast; choose the system for ambiguous CHD/CUE. Include every named track. |
| Flycast arcade | `.zip` | Choose Arcade instead of Windows files. Original set filename is retained. Flat stored/deflated ZIPs without archive comments; no encrypted, directory, link or traversal entries. Standalone complete sets only. |

Copies use `Files → Iridium → IridiumRuntimes/Games/<game ID>`. Saves/configuration
use `Saves/<runtime>/<game ID>`; writable system roots use `System/<runtime>`.
All are checked for nested symbolic links before launch. Flycast appends `dc/`
to its system root for BIOS/arcade files. Azahar's selected save-path option
appends `Azahar/` to the game's save root; supply any necessary system content
in that upstream user tree. Dolphin bundles the complete upstream `Sys` and
keeps user NAND/cards/configuration in the game's save root. Play!'s complete
`GameConfig.xml` is bundled at the upstream expected app-resource location.
Removing a library entry retains its files.

Generic controls expose A/B/X/Y, L/R, L2/R2, two sticks, Start and Select.
GameCube Z maps to R2. Wii minus/plus map to Select/Start, 1/2 to Y/X, Nunchuk
C/Z to L/R, and IR to the right stick. Wii Home uses the left thumb click.
Keyboard: arrows D-pad; WASD left stick; Z/X A/B; C/V X/Y; Q/E L/R; 1/3 L2/R2.
Physical thumb clicks are exposed; touch layouts can be customized.

## Rebuild and replace

Use the prerequisites in [actions-ipa.md](actions-ipa.md), functioning Xcode,
CMake and Ninja. Choose an installed Xcode with per-process `DEVELOPER_DIR` when
needed. Complete Xcode's supported first launch and Metal installation; never
reseal native receipts or omit essential shaders to bypass a missing compiler.
Reuse Madeira/PPSSPP only when their existing source/toolchain audits accept it.
If Apple has mounted Metal but Xcode cannot discover it, select that existing
`.xctoolchain` through process-local `EXTERNAL_TOOLCHAINS_DIR` (its parent) and
`TOOLCHAINS` (the identifier in `ToolchainInfo.plist`). Xcode's `-toolchain`
option plus `EXTERNAL_TOOLCHAINS_DIR=...` build setting can also select it.
Verify the resulting Metal compile command points into the installed toolchain;
do not copy compilers into Xcode or edit the toolchain metadata.

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
python3 ci/collect-madeira-source.py \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app \
  .build/phase3-source --link-maps .build/madeira-frontend-derived
python3 ci/package-unsigned-ipa.py \
  .build/madeira-frontend-derived/Build/Products/Debug-iphoneos/Iridium.app \
  .build/phase3-ipa
```

The recipe verifies the two official Azahar asset digests. Source collection
supplies the unified source; the iOS binary can be fetched and verified again.
To replace that binary with a source build, use the pinned upstream
`.github/workflows/libretro.yml` iOS recipe, retain export/install-name checks,
and update the receipt to identify the replacement. Simulator components build
with `python3 ci/build-phase3.py --engine all --sdk iphonesimulator --jobs 3`.
The simulator Azahar recipe selects software rendering and disables Vulkan.

The manual IPA workflow always includes all four console engine components.
`python3 ci/dispatch-build.py` builds the exact committed branch head with all
engines included. It never publishes a release. Monitor any dispatched
build at five-minute intervals and retrieve both its IPA and matching source.

Receipts record root/dependency pins, compiled files, recipe/ABI/overlay hashes,
exports, platform, binary hashes, resources and notices. Only zlib's verified
byte-identical `zconf.h` → `zconf.h.included` CMake rename is tolerated in vendor
source. Final app audits recheck all components/resources. Corresponding source
contains initialized pinned dependencies, overlay recipes, the Azahar unified
source, receipts, notices and build/replacement instructions. It excludes Apple
SDKs, signing credentials, games and private logs. [LICENSING.md](../LICENSING.md)
still controls the unresolved combined-app distribution review.

Pinned public TLS test keys and PEM-format markers are recorded by exact path,
digest and upstream Git URL in `ci/public-key-source-fixtures.json`; changed or
copied bytes still fail privacy checks. The four separately recorded upstream
Windows/test signing fixtures are excluded from corresponding source. They are
unused by the iOS targets and remain untouched in local upstream checkouts.

Dolphin's mbedTLS uses its supported user-configuration hook to disable the
optional self-tests and bundled test-certificate module in the player binary.
TLS, certificate parsing and PEM handling remain enabled. All original test
source and notices remain in corresponding source. This avoids shipping the
public test private keys; package privacy checks remain unchanged.

## Four-engine acceptance gates

Record source/build, model/OS, legal fixture/version, input method, observed
result and limits. Keep identifiers/private logs out of public evidence. For
each engine distinguish compilation, video, input, audio, saves and shutdown.

- [ ] **Dolphin:** device/simulator component audits; legal GameCube/Wii homebrew
  video; input/audio; pause/background/resume; card/config persistence; clean
  close followed by another console launch.
- [ ] **Azahar:** device/source digests and simulator source build; legal 3DS
  homebrew on both screens; lower-screen touch/input; audio; pause/resume; saves;
  clean close followed by another console launch.
- [ ] **Play!:** component audits; rejected JIT remains unavailable; supported
  allocator plus legal PS2 homebrew video/input/audio; pause/resume; card saves;
  close requires the documented process restart.
- [ ] **Flycast:** component audits; rejected JIT remains unavailable; legal
  Dreamcast homebrew video/input/audio; absent arcade prerequisites are declined
  clearly; pause/resume; saves; clean close and another console launch.

Component imports and builds do not establish successful gameplay or physical-device
compatibility. Record those results separately before making compatibility claims.
