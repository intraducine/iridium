# Changes from upstream

## Native console engines

The optional console engine target includes pinned DolphiniOS Dolphin, Azahar, Play! and
Flycast. Iridium hosts upstream runtime/Libretro implementations and adapts
rendering, audio, input, isolated storage and lifecycle through a C boundary.
It does not replace guest CPU/GPU/media implementations. Pins, build/replacement
instructions, limitations and the four-engine acceptance checklist are in
[docs/console-engines.md](docs/console-engines.md).

Declared CMake adapters hide C++ symbols. Dolphin uses upstream Metal/iOS with
plain interpretation and complete Sys resources. Azahar reuses its verified
official iOS core and matching unified source, with software graphics and
CPU/shader interpreters. Play!'s generated Libretro entry routes CAppConfig to
the game's save root; existing CodeGen allocation/protection calls now fail
before execution when Release assertions would disappear. Flycast's generated
GLSM advertises ES3 when its target compiles HAVE_OPENGLES3. Play!/Flycast probes
exercise their own allocators; no PSP JIT protocol is reused.

Generated Play!/Flycast session hooks call their upstream VM pause/resume paths
when the shared menu or an audio interruption pauses a game. Play! drains its
owner-thread GS mailbox without destroying the renderer. Flycast stops and
restarts its execution thread. The Azahar touch adapter accepts only the lower
screen of the selected top-bottom layout, excluding the top screen and bars.

Dolphin selects bundled dependencies, disables old zlib-ng NEON configuration
that passes ARM32 flags to arm64, and disables incompatible fmt consteval
declarations for Apple Clang 21. Original notices are retained. Source collection
maps all five libraries and includes receipts, dependencies and Azahar's source.

The consumer importer detects supported systems from existing format headers,
asks only for ambiguous containers, and retains GDI/CUE manifests with named
tracks instead of requiring conversion. Each source file is coordinated during
copy. RVZ uses its upstream uncompressed disc header; ISO SYSTEM.CNF BOOT/BOOT2
separates known PS1 from PS2. Shared Launch Support, system settings, onboarding
and import errors use contextual consumer copy. Runtime pins are unchanged.

## Prepared PSP executable arenas and owned helper shutdown

The PSP ARM64 component now negotiates a separate version-3 executable-memory
interface in addition to component ABI 3. It owns four fixed prepared arenas:
one 16 MiB CPU slot and 256 KiB vertex, pixel and sampler slots. The probe
temporarily borrows the CPU slot. Declared overlays replace ARM64 CodeBlock
allocation with checked RX/RW claims; unregistered executable allocation is
denied. Backing, handle metadata, roles and generations are bounded. Released
handles remain finite tombstones, and reuse requires actual reader/writer drain.
The PPSSPP, Madeira, StikJIT and idevice pins are unchanged.

A version-2 PSP-only protocol uses the app's existing owned BRK, `_M<size>,rx`
allocation and per-page memory-write operations. Only four exact sequence/size
pairs are accepted; the version and sequence are explicit registers. The helper
allocates and prepares RX before the app creates each shared RW alias. It rejects
caller addresses, malformed/out-of-range/overlapping allocations and mixed wire
versions. Current attempt/script/PID receipts carry the bounded private allocation
inventory. A proven allocation is retained for cleanup even when preparation
fails; ambiguous outcomes retain the owner for restart and never free guessed
addresses. Exact RX/RW, sentinel/coherence, restored-state and execution checks
remain mandatory. No app RX mprotect or unchecked SDK batch is used. Windows retains its
existing script and fault policy. Target detach return, D acknowledgment, the
original helper response after SDK cleanup, read-only self-task/retained-worker
exception-route comparison and a successful typed network-restoration result
are separate gates. Unsupported, incomplete or changed routing declines this
path. No exception-port repair, new permission, App Group or debugger opcode is
introduced. Initial observation failures retain a fixed subcheck code, numeric
errno/Mach result and saturated count in the same bounded journal. Terminal
interpreter fallback reasons are fixed numeric codes. These observations do not
change any acceptance gate or establish the unobserved iPhone API return code.
Durable restoration debt remains owed through relaunch recovery until a
correlated successful restoration of that input; PSP admission checks that debt.
Initial attach fields and process-qualified thread IDs are validated before
readiness. Only SIGTRAP/EXC_BREAKPOINT at the owned BRK immediate can mutate
protocol registers; other faults keep their existing forwarding path. The pinned
transport has no hard command timeout/cancellation: a UI watchdog cannot promise
recovery during all-stop, and uncertain workers retain their context and lease.

Only after teardown and restoration may the actual 42/7 probe promote a drained
CPU claim to the native generation. Full-width native-IR profiler stores use the
validated RW view. Checked write scopes, branch fixups and publication failures
propagate before callable results are exposed. Both generated CPU dispatchers
recheck core state after compilation, and latched failure prevents native-IR
cache-pressure retries. Patch translations are checked before arithmetic or
emitter construction, including cancellation after patch admission. A finished
probe closes its pass-local writer on every diagnostic failure.
Vertex exhaustion returns null
and size zero, keeps prior decoders intact, and uses existing generic decoding.
The software pixel/sampler ARM64 paths retain generic execution; their upstream
JIT bodies are AMD64-only. The earlier MOV chunk initialization correction and
probe byte/TLS checkpoints remain in place.

Host fixtures cover the shipping arena and observation implementations, helper
request/retrieval and normal export, launch failures and late returns, real
vertex lookup/compilation/exhaustion/fallback, and decoded far-alias profiler
stores. The Mac executes copied vertex bytes in its MAP_JIT test harness;
that does not prove prepared-alias execution after device detach/restoration.
No new device run establishes routing teardown, gameplay or the original crash
cause. These remain separate runtime review gates.

## PSP probe lifecycle parity and protection status

The bounded probe uses the pinned `ARM64CodeBlock` allocation, reset,
`BeginWrite`, cache flush, `EndWrite` and release lifecycle. Each pass changes
the written/estimated page span rather than the whole allocation. A declared
`Common/CodeBlock.h` overlay returns existing protection results from
`BeginWrite` and `EndWrite`; `EndWrite` clears its write state before returning
even on failure. This is lifecycle parity plus status propagation, not unchanged
upstream code or a proven device crash fix. Emission and execution decline on
failed transitions, and explicit release plus the destructor cover failure paths.
The ordinary non-prepared cleanup transition remains available outside the PSP
prepared path. The prepared path above owns alias scrubbing and release. The
execution guards, private breadcrumbs and existing fault policy remain in place.

Native component provenance records the staged CodeBlock header hash and a
compiler-dependency audit requiring every reference to use that staged header.
A clean native rebuild is required so Core and the probe share its interface.

## Bounded PSP JIT follow-up observations

The declared native overlay initializes all four `MOVI2R` chunk flags in
PPSSPP's pinned `Common/Arm64Emitter.cpp`; the unchanged production emitter
reproduces invalid bool reads under UBSan. Initialization preserves required
zero chunks when optimization is off. This is not evidence that the defect
caused the observed phone termination. The dependency revision is unchanged.

The constant-return probe records its emitted length and at most four words,
and a final checkpoint after resolving/touching its execution TLS. Madeira's
generated script/helper receive a declared diagnostic overlay: only allowlisted
setup acknowledgement categories and first stop/fault/exit classifications
reach a bounded private helper journal. The Windows debugger sequence and existing fault policy are unchanged; the PSP
strict preparation and shutdown sequence is described above. Generated source
verification checks both helper and script overlays. JIT permissions are unchanged.

The declared message/host/helper overlay adds read-only diagnostic retrieval
over Madeira's existing extension requests. App export mirrors bounded,
revalidated records with matching request IDs and per-enable attempt IDs,
including records retained after app termination. Retrieval has a deadline,
preserves earlier mirrors on unavailable or partial results, and never enters
pairing/JIT preparation. Stop metadata is parsed after the three-byte reply
prefix so first-field exception/code values retain their numeric classification.

The first non-BRK fault now privately retains a typed PC, second `medata` value,
field-count category and classification of the instruction read already performed
by the pinned script. Missing and invalid values are explicit; 64-bit locations
never pass through JavaScript Number. The helper's system log and app mirror
omit these locations, and ordinary export redacts private address records.
The native journal requires the probe allocation base and the app/native image
bases plus UUIDs before execution. Failure to persist an anchor declines the
probe. These are diagnostic observations, not a crash fix: cache/RX ordering,
emitter initialization, TLS checkpoints and debugger commands remain unchanged.

## Optional per-game PSP JIT

Iridium stores an additive, default-off PSP JIT preference in its console
library. PSP launches share Madeira's existing activation coordinator and
Launch Support settings. The native adapter checks PPSSPP's upstream code
allocation, W^X transitions, instruction cache, execution and rewriting before
advertising JIT. The fault guard is limited to the probe's generated leaf code
and restores prior signal dispositions. It declines validation before execution
when any custom fault handler is installed, preserving that handler's mask,
stack and delivery flags. A PSP activation owns the shared coordinator until the
native worker acknowledges completion and its network restoration finishes;
cancelled/stale continuations cannot release another activation. Restoration
finishes before the player starts, including interpreter fallback. Ordinary activation/validation failures
use the IR interpreter; a stalled probe retains runtime ownership. The component
ABI and build receipt require the matching validation entry point. No emulator
source pin is changed; the prepared PSP allocation boundary is described above.

## Shared player presentation and diagnostics

Iridium's generated app adapts Madeira's existing touch control model, buttons,
and mapping editor for console sessions, preserving its Windows input callbacks
and storing console layouts separately. Shared menu presentation keeps runtime
capabilities available. Touch pointer modes use viewport coordinates; configurable
haptics trigger on press transitions. No emulator pin or native engine is changed.

Windows keeps the pinned upstream controller reservation opt-in and synchronous
launch setup. The controls window uses the pinned upstream visibility, hosting
and attachment lifecycle. Layouts, input mode, menu suppression and lifecycle
release rules are preserved; no saved setting is rewritten.

The generated JIT coordinator admits one enable request until its failure cleanup
finishes. Shortcut callbacks carry a request identifier; late callbacks and open
failures cannot finish a newer operation. Failed cleanup remains owed for later
recovery. Start and completion cleanup remain distinct operations.

The portrait shelf places title and actions beneath the header and gives covers
available space without an empty band above them. Landscape keeps title and
actions on one row. The Windows HUD installs its host before showing the window,
refreshes it on activation and rotation, and uses a native 48-point menu target
with matching accessibility bounds. That target hides while the menu is open.

The console bridge records runtime steps, fresh video callbacks, changed images,
audio and input separately and forwards bounded core log messages. These are
liveness and presentation measurements, not proof of game progress. In-game
Diagnostics and Settings export bounded, sanitized copies of the relevant logs;
original logs and credential stores remain untouched. The compact library keeps
its leading focus slot, follows the nearest cover during native scrolling, and
truncates titles to one line. Pointer modes are explicit Trackpad/Direct settings;
control surfaces retain touch ownership and clear held inputs on cancellation.

## Multi runtime frontend boundary

Original Iridium code adds an additive console library and a runtime driver
contract. Madeira's native source stays pinned and unmodified. The generated
app has four explicit guards at its Windows/Dock launch entry points to prevent
overlap with a console session, and its bridging header imports the new core
boundary. Its library view combines Madeira records with isolated console
records. Existing Windows callbacks, settings, media and saves remain Madeira's.

SameBoy's pinned Libretro C core is compiled as a separate static archive. The
builder generates upstream replacement boot arrays and a complete private
symbol namespace; it changes no vendored files. SameBoy is pinned to 1.0.4 at
`98da08c3117a7bf39c7329fc662c0d18cb54707d`. Its unchanged Libretro adapter
accepts the host's 96 kHz target rate. The host supplies standalone iOS model,
color-correction and high-pass defaults, uses bounded audio prefill and frame
catch-up, and preserves unused legacy RTC files. Core and APU source are unchanged.
Build/reuse verification covers source, headers, boot data, recipe, namespace and
archive bytes. The seven boot images are assembled from the pinned source
using RGBDS 0.9.4 and stored as reviewed hexadecimal build inputs with source
and output hashes; ordinary builds verify them without needing an assembler.
Iridium supplies bounded
software video/audio callbacks, joypad input, and battery/RTC save handling.
The corresponding-source collector includes the initialized SameBoy gitlink
and original notices along with the build generator. See `docs/multi-runtime.md`
for validation scope, migration, recovery and currently unsupported engines.

## Madeira frontend target

`vendor/Madeira` is pinned to `48f976429c189f8396e23d251d8a82f43c705922`.
Its four runtime submodules keep the exact revisions selected by that commit.
`ci/madeira-frontend.py` generates a separate app project under `.build`.
It replaces the root library with `iridium/apps/ios/MadeiraFrontend`, selects
that interface at startup, and adds an X-button Play command to the library
menu publisher. `ci/madeira_presentation.py` groups the original settings and
game options into pages, applies a shared artwork backdrop, and organizes the
player menu. It keeps the upstream controls, bindings and action callbacks.
Explicit navigation-bar visibility and inline titles keep page safe areas
stable. The player uses native glass on iOS 26 and material on older systems;
Reduce Transparency uses an opaque surface. Close Game asks for confirmation
before calling the original graceful close action.
The app identity, version and icon use Iridium's values. These are the declared
app-source hooks. The original launch, JIT provider, game surface, input, Steam, downloads,
media, memory, and save implementations remain upstream code.

The frontend adds Favorites, a horizontal cover shelf, and links to the native
features. Its optional import copies an existing first prefix and subsequent
game/save files into Madeira's shared prefix. It preserves original folders,
checks path containment and conflicting files before copying, and converts
the old artwork, title, arguments, favorites, and touch-layout records. Different
saves with the same name stop import. Separate Wine registries are not merged.

The cold native build reconstructs the missing wineserver base archive with
the upstream compiler flags, then runs its original replacement-object script.
It supplies an explicit arm64/generic FEX host configuration on macOS, builds
the original allocator-hook archive, and refreshes the app's GPL and Converter
Exception copies from the pinned root notices. LLVM 15.0.7's two Darwin checks
also accept iOS. Newer Metal compilers use the public relaxed threadgroup atomic
operation in a generated tessellation shader instead of the changed private
intrinsic. The installed iPhoneOS Metal tool can compile the original macOS AIR
command target when the macOS tool lookup is absent. These are build adapters;
the pinned source trees remain unchanged.

The frontend orchestration stages rebuilt GnuTLS, Hogweed, Nettle and GMP
archives at the app's existing link paths and records both prefix and app
hashes. Its ntdll adapter stops on any failed compilation before archiving or
installation. Its i386 adapter preserves serial retries, but retries every
selected target after bulk failure, including existing DLLs. Failed retries
prevent installation and a new completion record. These checks adapt the pinned
recipes in memory without changing vendored source.

Native build completion is saved before packaging, with a 14-day reuse limit
and checks for matching inputs and output archives. The local frontend builder
also builds Madeira's untracked i386 farm with its original Wine/DXMT recipe
and validates all three architecture farms before packaging. The i386 outputs
use their own 14-day completion record, so a packaging repair does not repeat
the native build. The local frontend command
is `bash ci/build-madeira-ipa.sh`. Hosted Actions uses the same native/i386/app
steps, retains completed components before packaging for 14 days, and collects
matching source and notices. The app build disables Debug's separate dylib so
its runtime libraries appear in the final executable link map. Source archives
retain dependency revisions and can be rebuilt without Git metadata.

## Global sync setting in the consolidated v0.2.1 app

Original Iridium Swift code exposes Fastsync, Madsync and Wine standard sync in
Runtime settings using Madeira's existing `madeira.cfg` engine selection. It
saves only after an explicit choice, writes both sync keys atomically, and
preserves unrelated unified entries. When no unified file exists, it carries
legacy one-value, environment and DXMT settings forward while retaining the
original files; invalid text and unsafe early-lookup migration block the save.
Opening settings does not migrate or rewrite configuration. File I/O stays off
the UI thread. The host prevents launch during a save or before a required cold
restart. Vendor sync implementations, installer exceptions, and server wake
policy are unchanged. No upstream application UI code or dependency is added.

## v0.2.1 Madeira package profile

Normal Madeira builds omit the legacy Linux userland, runtime-host executable,
and translator resource bundle. The Madeira adapter always selects native iOS
Wine; the historical `IRIDIUM_RUNTIME=legacy` override no longer switches it.
Staging, finalization and packaging validate the native resource inventory and
remove stale legacy copies after SwiftPM copying. Local native refreshes record
producer identity without building or extracting a Linux bundle. The manual IPA
workflow no longer produces Linux userland, and source packaging requires sources
for the retained components. Legacy source/build recipes and dependency notices,
shared embedded bridge link inputs, ANGLE/media frameworks, and both 64-bit and
32-bit Windows modules remain. Existing library data and saves are unchanged.

## Optional physical-controller keyboard and mouse mapping

Sources: https://github.com/willfaust/Madeira/pull/128 and follow-up
`6722178dd9b93898b812ae9be6130565d92652fc`, inspected against
`4e9d45a74294cd820120791c4b3f2b79adf4fc70`.
Madeira application sources are GPL-3.0-or-later with the Madeira Converter
Exception, version 1; the retained license and exception are in
`testrepos/Madeira/COPYING` and `testrepos/Madeira/LICENSE-EXCEPTION.md`.

Iridium adapts Madeira's WASD/button template, eight-way stick directions,
disconnect releases, and elapsed-time mouse movement into its main-thread
polling bridge. It keeps native controller mode as the default and touch
layouts independent. UUID-scoped input preferences store the optional mode
and bindings without changing existing library files. Unlike the upstream
player-one mapper, all four existing physical slots can map input; shared
outputs are coalesced across buttons, sticks, controllers, and hardware keys
or mouse buttons. Only the strongest mouse stick moves the cursor, and
subpixel carry uses elapsed time without a minimum interval. No upstream
callback handlers or runtime gamepad transport are imported.

## Moonlight iOS touch input

Source: https://github.com/moonlight-stream/moonlight-ios/blob/85af0f75622bb2636481afda8b0fc5cc33d5956e/Limelight/Input/OnScreenControls.m
Original by Diego Waxemberg; copyright (c) 2014 Moonlight Stream.

`TouchControllerOverlay.swift` uses a separate UIKit touch target for each
control, following Moonlight's touch-down, move, release, and cancellation
pattern. It does not port Moonlight's `OnScreenControls` class. The controller
images in `iridium/apps/ios/Iridium/Assets.xcassets/` are copied from
Moonlight iOS at the same revision. Iridium retains its saved positions and
uses its own XInput bridge; it does not use Moonlight's streaming transport.
The GPL-3.0 license is retained in
`iridium/apps/ios/MadeiraSupport/Notices/Moonlight-LICENSE.txt`.

## Launch and shutdown corrections

- `WineProcessBridge.m`: accept bounded JSON argv arrays from Iridium without space splitting; expose the root process exit code and use atomic liveness state. Preserve the older Madeira developer argument interface.
- `WineProcessBridge.m`: set Wine's profile user to `madeira` before startup, repair existing `users\mobile` registry paths, and merge legacy profile files without overwriting saves or following directory links.
- `Winios/Winios.m`: remove the direct per-keystroke trace, including software-keyboard input.
- `Winios/Winios.m`: attach installer desktops below Iridium's player controls; report desktop Metal frames through drawable-presented callbacks and keep the cursor on the active surface.
- `WineServerBridge.m`: publish atomic liveness and clear it on thread cleanup, including fatal startup exits. No forced thread cancellation is added.


Source snapshot and privacy edits: 2026-09-10. Existing notices are retained. This is a modified source distribution.

Iridium app changes include Madeira runtime integration, JIT helper support, media and input integration, and library/navigation changes. Legacy runtime forks include the Iridium iOS bridge and build support. The upstream records below identify base revisions; they do not assert a byte-identical copy.

## testrepos/Madeira
Upstream: https://github.com/willfaust/Madeira
Base revision: `8c050d03f4d89096e1e2e2c8bb44479fffd86619`

Local modified source paths included in this snapshot:
- `app/Madeira/ContentView.swift`
- `app/Madeira/StikJITHelper.swift`
- `app/Madeira/WineProcessBridge.m`: select native ARM64 Wine for ARM64 executables by their PE header, including installer helpers given as full Windows paths.
- `build/madeira-d3d12/deps.sh` and `fetch-converter.sh`: use a checksum-pinned release dependency for hosted builds, retaining an official local-installer override and Apple notices.
- `build/ntdll-unix/build.sh`
- `build/ntdll-unix/signal_arm64_ios.c`: handle integer store-pair address updates in both exception paths.
- `build/ntdll-unix/virtual_ios.c`: correct bitset indexing when retargeting thread-data reads in JIT code; remove unbounded diagnostic stack scans from allocation paths.
- `build/win32u-unix/message_ios.c`: poll the iOS input ring during game message waits, preserving caller deadlines and WaitAll behavior.
- `build/win32u-unix/driver_ios.c`: report input delivery errors and foreground-window changes beyond startup.
- `build/wineserver/build.sh`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/FEX

Iridium uses an app-reserved host arena in Wine and FEX. Wine publishes that reservation through the upstream arena handoff.
FEX host allocations remain inside that arena. The compact allocator and
thread failure corrections remain in the tracked build patches.

Upstream: https://github.com/willfaust/FEX
Base revision: `0f8edf8f6383ae8085e0ffac511c789cdae97514`

Local modified source paths included in this snapshot:
- `FEXCore/Source/Interface/Core/Core.cpp`
- `FEXCore/Source/Utils/ArchHelpers/Arm64.cpp`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/wine
Upstream: https://github.com/willfaust/wine
Base revision: `723d1bf5132768276cea9bc35ab59c83557bb5fb`

`dlls/ntdll/arm64ec_x64_export_iat.c` is supplied from Will Faust's source
commit `32810bdeb4b9e72b02320e9b72ce3ba03ceee3d7` (LGPL-2.1-or-later).
The public base includes it from `loader.c` but omits the file. Iridium includes
the complete helper source so a clean checkout can configure Wine.

Local modified source paths included in this snapshot:
- `dlls/ntdll/sync.c`: retain ARM64/ARM64EC diagnostic timers and use Wine's performance counter on other architectures.
- `dlls/ntdll/unix/sync.c`: restrict Apple thread QoS and Mach alert timing to Apple builds, and the ARM yield experiment to ARM64; Linux prefix builds keep their futex wait path.
- `dlls/ntdll/loader.c`: restrict the JIT alias lifecycle diagnostic to ARM64EC, where its helper is defined; preserve the ARM64EC diagnostic.
- `dlls/ntdll/signal_arm64ec.c`: guard loader image notifications against recursive FEX memory callbacks while preserving the caller's callback state.
- `dlls/win32u/dibdrv/bitblt.c`: restrict iOS source-bitmap debug hooks to `WINE_IOS` builds so desktop Wine links without iOS app symbols.

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/research/dxmt
Upstream: https://github.com/willfaust/dxmt
Base revision: `ca8a2516d819e7e1f366981825ad1f0d26f80fdd`

Local modified source paths included in this snapshot:
- `src/airconv/shaders/air_tessellation.metal`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## Manual build preparation (2026-09-10)

- Native dependency downloads are locked in `ci/runtime-inputs.json`. Source archives retain upstream notices.
- The downloaded LLVM 15 source receives Madeira's documented `Darwin|iOS` linker selection patch in `ci/prepare-native-runtime.sh`; the unchanged archive digest and exact patch are recorded in the repository.
- Madeira's GMP/Nettle/GnuTLS and FreeType build helpers accept a compiler job limit. The ntdll helper now stops on a compile failure rather than reusing stale objects.
- Iridium media SDK paths are checkout-local. Media compiler jobs honor the same limit. No runtime behavior or signing identity is changed.
- Build-tool and SDK downloads are not committed or distributed by this source change. Complete component source and license inventories remain required before a binary release.

## Remaining runtime recipes (2026-09-10)

- Added CI recipes for Wine PE modules, ARM64EC FEX, DXMT, ANGLE, source-built GStreamer, source-built idevice/StikJIT, and the legacy userland bundle. No application runtime behavior was changed.
- Madeira prefix generation now uses a marked temporary directory, fails on wineboot failure, waits for its server, and removes host links and registry identities before archiving.
- The legacy Wine Linux builder enables Debian source repositories and includes Python for exact dependency-source collection.
- StikJIT's fetched prebuilt FFI archive is excluded from linking. Its replacement is built from a documented source revision.
- Explicit unresolved source/license items keep IPA publication blocked. No local compilation or manual IPA workflow was run.

## Corresponding-source collection (2026-09-10)

- Recorded the exact StikDebug script comparison and retained its AGPL text: legacy.js is identical; universal.js changes only the default logging level.
- Added source collection at build stages, using Cerbero's existing bundle-source command and Git archives. The collector excludes prebuilt JIT archives and rejects signing files or escaping source links.
- Added matching-source packaging and a source checksum beside the future unsigned IPA. Resolved dependency license and correspondence audits remain required before upload.

## Wine source completeness (2026-09-10)

Restored tracked legacy Wine Makefile.in templates omitted from the initial public snapshot. Compared against Wine 11.4 commit `cc893ef9cb17b994bfd1f1a1f7355be55e615623`; existing fork modifications in nine templates are preserved. These are source build descriptions, not generated Makefiles. Removed the incorrect Makefile.in ignore rule. Source checks now verify that every configured Wine subdirectory has its template.

Also restored nine fork-specific templates and required text .spec/.in inputs from the existing local source. No compiled outputs or game data are included.

Restored the remaining legacy Wine .spec export definitions and removed their incorrect ignore rule after the next clean build identified an implicit MODULE dependency. Source checks now cover implicit module export definitions, not only explicitly listed sources.
- Cerbero 1.28.6: select C++14 for the gperf 3.1 host-tool recipe. Its legacy `register` declarations fail with the newer compiler's C++17 default. The exact recipe patch is retained in `ci/patches/cerbero-gperf-cxx14.patch`; codec language settings are unchanged.
- Cerbero 1.28.6: fetch spandsp 0.0.6 from GStreamer's source mirror after the original host began redirecting to a domain-sale page. The original SHA-256 remains pinned in `ci/patches/cerbero-spandsp-mirror.patch`.
- Cerbero source packaging includes a MANIFEST.in patch to retain recipes, nested patches, configuration, package definitions, tools and the launcher. This changes the source archive, not codec compilation.
- Cerbero restores nested Meson source and patch archives from its supplied cache after checksum verification. The patch is retained in `ci/patches/cerbero-meson-source-cache.patch` so offline WebRTC/Abseil builds do not need a network download.

- GStreamer 1.28.6 applemedia: test whether the selected target can use
  AssetsLibrary before compiling and registering iosassetsrc. Keep AVFoundation
  and VideoToolbox elements enabled. The Cerbero recipe and source patch are
  retained in `ci/patches/cerbero-assets-library.patch` and included by the
  existing Cerbero source-bundle mechanism.

### ANGLE build configuration for Xcode 27

The CI recipe uses the selected Xcode compiler, compiler runtime, C++ library,
linker and archive tools. It builds only the Metal backend, with WebGPU disabled.
Upstream diagnostics remain visible but do not become errors under a newer
compiler. The former unknown-attribute suppression and libc++ infinity patch
are removed; ANGLE and its dependency source files remain unchanged.
The graphics source archive includes the separately pinned bootstrap depot_tools.

### idevice Cargo workspace

The CI recipe excludes its generated `vendor` directory from the idevice workspace
so vendored build scripts can invoke Cargo independently. Vendored crate manifests
and checksums are unchanged. The modified workspace manifest is included in the
corresponding-source archive.

The vendoring step also synchronizes plist_ffi's published lockfile because its
header generator resolves dependencies independently. Both locked graphs remain
unchanged. Full offline metadata resolution is checked before JIT compilation.

### Media source collection

Release packaging collects the exact SDK MoltenVK source and its pinned external
sources without rebuilding the retained library. Upstream license texts are
copied unchanged into the app notices. Cerbero's source distribution gains a
manifest for its recipes, patches, configuration, package definitions and tools.

Rust standard-library source collection now includes registry dependencies from
each toolchain's library lockfile. Original crate archives and notices remain
unchanged; the collector checks Cargo's recorded SHA-256 digests before packaging.


StikJIT's Swift 6.4 textual interfaces receive a targeted nested-type separator
correction after compilation or restoration: `StikJIT::StikJIT::` becomes
`StikJIT::StikJIT.`. The module selector remains intact. The binary is unchanged.
CI imports a staging copy without its serialized Swift modules to verify the
textual interface before attempting the app build.

- Cerbero restores bundled Cargo dependencies and rebuilds their source settings from Cargo.lock for offline builds. The patch is retained in `ci/patches/cerbero-cargo-source-cache.patch`; Cargo still checks the locked dependency graph and vendored checksums.
# Native Steam integration

Added an on-device SteamKit2 3.4.0 module, SwiftUI account/library/download flow,
device-only Keychain session persistence, verified resumable Windows depot
downloads, and registration into Iridium's existing runtime library. SteamKit2
3.4.0 is built from its pinned source with `ci/patches/steamkit-ios-process-start.patch`:
iOS/tvOS use the client creation timestamp for job IDs because Process.StartTime
is unsupported there. Other runtime dependencies are unmodified; NativeAOT reflection and generic roots are
owned by the integration. See `iridium/packages/steam/THIRD-PARTY-NOTICES.md` and
`docs/decisions/native-steam-downloads.md` for dependencies and architecture.

## Madeira runtime update (2026-09-29)

The runtime follows Madeira `d5a8e0a6`, Wine `daa17d04`, FEX `2838f3be`,
and DXMT `a5e0cd3d`. Full revisions are in `UPSTREAM-SOURCES.json`.
The integration adds the i386 Wine farm, FEX WoW64 translator, native D3D9
backend, WoW64 Unix-call tables, and updated graphics and media code.

Iridium keeps its Steam interface, controller and keyboard routing, JSON launch
arguments, profile repair, shutdown handling, and device-budgeted FEX arena.
The native parser uses the FFmpeg libraries and headers already supplied by
Iridium’s source-built GStreamer SDK. The existing GStreamer path remains the
64-bit media default; Madeira’s new native media tables serve WoW64 callers.
Metal shaders target iOS 18.0. Compiler output for both FEX translators and all
three Windows architectures is retained before staging.

The D3D9/DXSO import retains LGPL-2.1-or-later and its copyright notices.
The updated DXMT notice and LGPL text are included in the app notices.
Madeira’s Swift frontend, Dock Steam client, and unrelated test launchers are
not part of this integration. Iridium retains its existing verified Apple
converter download and checksum configuration.

## Madeira runtime fixes (2026-09-30)

Updated the backend to Madeira `40d5e748`, Wine `4f5b1971`, and FEX `26859e18`.
DXMT is unchanged. The update includes FastSync, bounded host CPU indices,
thread cleanup, native network and DNS calls, multichannel audio mixing,
read-only mapping repair, and guest display-mode changes. The selected monitor
size now reaches Iridium's touch routing and player layout.

Iridium retains its unconditional image-map callback guard, input routing,
device memory budgets, save-path repair, and shutdown handling. The shared
backend includes dormant Dock hooks; Dock and Madeira's frontend are not enabled.
Upstream host checks run with Iridium's existing source checks. CI removes source
collection copies and link intermediates only after the source and final app
audit uploads succeed, preserving the archives used to link the app.

## Game prerequisite installers

`IridiumSteamInstallScript.swift` adapts Madeira's `DockInstallers.swift` at
`40d5e74848e4ee7060e879c07ef74487d9dc8cec`. It preserves repeated installer
sections and adds a prefix-local default key for manual imports. Invalid pending
commands fail before any installer group is recorded as complete.

`prerequisites.c` adapts Wine service-manager startup from `willfaust/madeira-dock`
`src/scm.c` at `3cadfbea700e4da4b04e331dd7ef1ba633dfacef`. It runs included EXE
and MSI installers, records successful groups through Wine's registry API, then
starts the requested game in the same session. It does not use the Dock client.
Cancellation prevents later installer steps from starting and leaves incomplete
groups unrecorded, while preserving receipts for groups that fully succeeded.
The sources retain 125hz's copyright, GPL-3.0-or-later, and Madeira's converter
exception. Shared redistributables are copied only when available. GDI shared
sections, the session sync setting, and missing-only `fusion.dll` placement
follow Madeira's installer path. Existing game files and saves are preserved.

## Scoped Madeira compatibility ports for v0.2.1 (2026-10-03)

These are selected source ports, based on Iridium PR61 commit
`c74a032679d746f77485ca868c0bdef1b419952d`. The baseline snapshot revisions in
`UPSTREAM-SOURCES.json` remain unchanged; its `ported_changes` records identify
all additional source commits. The upstream reference inspected was Madeira
`4e9d45a74294cd820120791c4b3f2b79adf4fc70`, not a wholesale snapshot update.

- Madeira #107, `c62b9b29ae6da1d28192baa4354f6b4e73140225`, with mandatory
  `374956226743873395c0365ca790090d7815511f`: anonymous guest RWX data heaps use
  plain host memory. Eligibility requires original RWX allocation protection,
  a size of at least 64 KB that is not a 64 KB multiple, and eligible neighbours
  across host-page rounding. Native EC code, JIT pool/alias-backed allocations,
  images and file mappings retain their existing paths. The size rule remains
  a heuristic. `MADEIRA_GUEST_RWX_DATA=0` restores the previous behavior.
- Madeira #110, `bcf54a365a0e5a69292628d8e91eb963e2e70b6f`: shared writable PE
  sections that cannot be mapped on host-page boundaries fall back to private
  image contents. Their writes are not shared between processes. Aligned shared
  sections and other mapping failures retain their existing behavior.
  `MADEIRA_SHARED_SECTION_PRIVATE=0` disables the fallback.
- Madeira #111, `1bbaf6be2a92fe6887c8a09fcd4e1b0c2fa5505f`: images with stripped
  relocations may claim the existing executable window below the 64 MB floor.
  Bounds, retirement and commit/rollback handling are preserved.
  `MADEIRA_EXE_WINDOW_SMALL_FIXED=0` restores the floor for these images.
- Madeira #119, `c7191a36fa0faba366f77c775f12d636af5c0e5e`, with
  `72d1a71eaa2713a470734474ae3e3f9a679e1ef4`: native D3D12 color
  `ResolveSubresource` records a load/store/resolve pass, creates a render-target
  stand-in when necessary, handles view-compatible destination formats, and
  replaces the stand-in when dimensions or format change. A single-sampled
  source takes the existing copy path. Depth resolves and
  `ResolveSubresourceRegion` remain unsupported.
- Madeira #120, `0c6764ac273932c32d2e0956df85c5dd9885c108`: native-ready IL-only
  .NET children publish the promoted native machine and do not arm an i386
  guest window; ordinary i386 children retain the guest path.
- Madeira #125, `4612deeb75599da9760d850e04843a550ca461eb`, with mandatory
  `cc20babfb175215465a08fd8dde242f7a9843eaf`: publish wineserver readiness only
  after registry loading. Iridium waits on its existing boot worker, checks
  cancellation and server liveness, and waits up to 30 seconds for slow registry
  loading rather than launching Wine against an unfinished registry. Atomic
  liveness and fatal-thread cleanup are retained. `MADEIRA_FAST_SERVER_START=0`
  keeps a two-second minimum delay, then continues waiting for readiness up to
  the independent 30-second deadline. Both modes remain cancellable.
- Madeira #129: DXMT `3a78f7a8211cd36999ea1e3c147f0e077eabfefc` and Madeira
  `1fae83a0ae01b573326bdb6d51a176cf43366ba7` supply the Metal 3.1 language
  pin and cache invalidation. The PE Meson generator also uses the upstream AIR
  macOS 14 target. Native command metallibs keep Iridium's existing `iphoneos`
  SDK and iOS 18 AIR target with a fixed `-std=metal3.1`; the auxiliary AIR
  preparation recipe is unchanged. The command-library header is invalidated
  when its build script changes. Existing `research/dxmt` paths are preserved.

The Madeira ports retain GPL-3.0-or-later and the Madeira Converter Exception;
DXMT retains its upstream and Madeira notices. Original port authors are
JesseLovelace (#107, #119, #120, #125), 125hz (#110, #111, DXMT shader pins),
and Will Faust (mandatory follow-ups and the native shader target adapter).
No binary, dependency gitlink, FEX source, signing material, frontend, input,
Steam feature, cage-release policy or experimental CPU/fault/AVX series is
included. Existing corresponding-source collection includes the changed tracked
sources and build recipes; no newly linked dependency is introduced.

Host regressions exercise the extracted allocation/window/section/child/startup
logic and D3D12 commands with platform stubs, plus the shader recipe with tool
stubs. Swift wait coverage runs when `swiftc` is available. These checks do not
establish Apple compilation, AIR acceptance, physical-device behavior or game
compatibility; those require separately authorized builds and device validation.

## Pinned PSP component

Iridium builds the unchanged PPSSPP Libretro target as an isolated Apple dylib.
A separate companion exposes only asynchronous boot status. Iridium owns the
UI, import metadata, serial stepping, bounded frame/audio delivery, per-game
memory-stick paths and teardown coordination. The initial adapter uses the IR
interpreter and software renderer, with no native JIT or networking advertised.
The Apple recipe, export audit, selected support assets and source receipt are
maintained outside upstream. No PPSSPP emulation source is rewritten.

Corresponding-source collection omits only the digest-verified public UWP
signing fixture, which the iOS Libretro target does not use. Its pinned upstream
URL, path, SHA-256 and exclusion reason are recorded in the component manifest.
The upstream checkout is unchanged; unreviewed signing files stop collection.


## Native PSP frontend integration

The PSP source moves to published PPSSPP v1.20.4,
`fa50bb1976065c4f8b1b47af227d367fe9771555`, with its exact selected dependency
pins. Madeira remains `48f976429c189f8396e23d251d8a82f43c705922` and its nested
pins. The previous Libretro/software-rendering PSP adapter is replaced in this
frontend by the native iOS engine with FFmpeg media, OpenGL and Vulkan graphics,
and the complete release resource tree (with the licensed atlas replacements
below). IridiumConsolePlayer supplies the shared menu, loading presentation,
touch controls/editor, feedback, keyboard/controller routing and diagnostic UI.
The embedded controller is a display-only child. Its upstream touch widgets,
loading widgets, pause screens, controller registration and keyboard ownership
are removed by ci/ppsspp_frontend_overlay.py; this is not a hidden second UI.
PSP firmware utility dialogs remain in the emulated game/PPGe renderer.

The ABI 2 boundary samples Iridium's source-aware input queue immediately before
sceCtrl's existing controller latch sample; no sample or emulation algorithm is
replaced. Resizes use the same asynchronous render drain as pause/close. Native
boot completion is distinct from renderer initialization. Engine failures and
menu requests return to the shared Iridium session. Resolution changes and five
save/load slots are requested from that menu and applied by the native render
owner after resume; completion callbacks reject retired session generations.
Callback ownership also completes policy-rejected save-state requests when
upstream drops every callback copy without invoking it. Queued operations keep
that ownership until completion; no timeout releases an operation still running.
The frontend-owned AutoRun debugger preference is normalized after configuration
load so preserved AutoRun=false cannot strand boot in an inaccessible debugger.
Boot status reports the effective core's CPU mode through the existing event
bridge; the shared menu does not assume the default or alter the selected mode.
No new save format or memory-stick migration is introduced. Settings not yet
exposed by Iridium keep their existing per-game configuration values.
Fresh PSP settings default to OpenGL, two-times resolution and IR interpreter.
Existing per-game settings and writable memory sticks are retained. JIT remains
unavailable until the native PSP code allocation path is independently verified.
No emulation Core, HLE or GPU algorithm is changed.

The out-of-tree overlay adapts app entry/lifecycle, scene screen lookup, rotation,
file/photo presentation, per-game memory-stick ownership and optional IAP guards.
The embedded session cannot relocate its managed memory stick. Upstream
configuration storage remains intact; interface-owned touch, debugger and
rotation flags are overridden for the shared player. App-active/interruption
state and user play intent jointly control resuming after asynchronous render
drain. Explicit stop cancels a pending backend restart. Render-owner and loop
identities reject delayed callbacks from retired or restarted controllers.
Camera, GPS, motion and picker owners are canceled and drained before teardown;
weak sensor delegates and ARC for the base controller remove their ownership
cycles. Queued gamepad, photo, keyboard and platform callbacks are session scoped.
The host supplies purpose descriptions and its application orientation mask.

Renderer and UIKit teardown occurs on main. Render and sensor drains keep the
UI run loop available until their work has stopped. NativeShutdown then runs
synchronously on main, matching Common/System/NativeApp.h and the pinned iOS
SceneDelegate restart path. Environment observers remain registered through a
backend restart, and mandatory cleanup continuations remain runnable after the
session is retired. The host has no hard UI timeout while upstream's synchronous
NativeShutdown joins workers and saves configuration. Real UIKit/device teardown
latency remains an acceptance requirement; a successful build or injected worker
stall does not establish it.

The builder replaces the PPSSPP MoltenVK prebuilt link input with MoltenVK 1.2.9
from the existing locked source closure. Original source files are verified
against their archives, upstream generated headers are prepared, and a final
link inventory proves which static archives were used. Corresponding source
includes all nine locked MoltenVK source archives and the build/replacement
recipe. The binary receipt retains compiled-source, dependency, resource and
archive hashes. Full TTF and identified PGF family grants are included. The separate UI/PSP
atlas resource replacements are described below; combined proprietary converter
terms remain an explicit distribution-review limit in LICENSING.md.

Host regression tests exercise actual lifecycle, renderer-drain, camera,
presentation, orientation and gamepad callback methods with platform stubs.
They do not establish God of War loading, audio, graphics, saves or input on a
physical iPhone. Private build success must not be described as fixing the
reported white screen until a matching device run reaches gameplay.

The separate licensed native PSP resource patch replaces only font_atlas.meta,
font_atlas.zim, ppge_atlas.meta and ppge_atlas.zim at packaging time. It preserves
all 4,427 UI and 4,568 unique PSP glyph lookups, historical range order, the
UBUNTU24 font ID and four PSP image IDs/sizes/texels. Other resources and runtime
pins/backends are unchanged. The out-of-tree host recipe compiles the upstream
rasterizer and actual metadata/ZIM readers, adapts historical input ranges,
initializes undefined missing records, and checks serialization against actual
rasterizer pixels. It pads GE textures, retains icon pixels and fits two vertical
repeat glyphs to horizontal cells. Scalar host RGBA4444 conversion avoids observed
Clang vectorization errors. Full font input notices and a generation receipt
accompany the resources. New corresponding source includes the locked inputs and
omits only exact superseded upstream atlas bytes. Previously delivered personal
IPAs and source packages remain intact. See ci/psp-atlas-host/README.md for the
specific host adaptations, metric deltas and remaining device acceptance limits.

### Native OpenGL synchronization correction

The release pin remains `fa50bb1976065c4f8b1b47af227d367fe9771555`.
`ci/ppsspp_gl_sync_overlay.py` adapts only GLRenderManager's completion protocol
in the generated native source. An empty host drain acknowledges no GPU work.
Each synchronous readback waits for its own completed SYNC request; publication
and waiting share a mutex so immediate completion cannot lose its notification.
Shutdown and skipped GL work cancel readbacks without copying GPU memory.
Monotonic request IDs prevent an old completion from releasing a later request.
The iOS embedding drain also waits for both the joined producer and the empty
render queue, matching upstream's shutdown contract before pausing display.

The native build audits compiler dependencies to ensure every GL translation
unit uses the adapted class layout. Component receipts include the compiled
translation unit, header audit and both generated source hashes. App preparation
rejects a component built before this correction. Corresponding source retains
the immutable upstream tree, the transformation and its deterministic race
tests. No game-specific emulation workaround or backend switch is introduced.
Host protocol tests do not establish that Ghost of Sparta is fixed on a phone;
that requires a new run of the delivered patched native component.

### PSP JIT diagnostic boundaries

Iridium's host bridge and native adapter add an ABI-3 diagnostic entry point and
a bounded, synchronized stage journal around JIT preflight and its launch/
restoration callbacks. Required records precede loading, protection, emission,
cache preparation and generated execution; a failed writer cannot authorize
JIT. The existing signal handler saves only the fault signal and generated-code
offset before its existing recovery jump. Records and handler-restoration status
are written after recovery in ordinary C flow. A native error sink is available
before preflight and keeps only fixed failure codes and explicit upstream errno
values. The adapter, probe and diagnostic header hashes invalidate stale build
receipts. No PPSSPP source, allocator, protection, cache implementation, debugger
policy, Game Boy behavior or runtime-switching guard is changed. See
`docs/multi-runtime.md` for journal limits and the remaining device evidence gap.

### PSP owned-operation observation contract, version 2

The app/native prepared-memory interface now negotiates version 2. Its shutdown
proof covers the exact correlated helper operation, readable self-task and
retained preflight-worker routes, and a successful self P_TRACED query. It makes
no host-wide or unrelated-thread cleanliness claim. Version-1 native components
and shutdown receipts are refused. The helper wire protocol is unchanged.

One private thread survives baseline capture, four arena requests, owned BRK/D
acknowledgment, the original SDK completion, network restoration and the 42/7
probe. Main-thread networking remains asynchronous. Required getters and exact
worker identity must succeed both after SDK completion and after restoration,
before execution. PSP preflight installs no Mach exception handlers, so an
explicit non-null task/worker route is unknown and refuses admission; matching
arbitrary routes never establishes ownership. Copied rights stay private and
are released after their retained work. Cancellation never interrupts a live
helper call or releases an uncertain native context. The real 42/7 result is
still required for promotion; future emulator execution remains device evidence.

This removes the incompatible privileged-host query without adding permissions,
exception-port setters, debugger commands or platform setting changes.

The helper receipt also persists bounded numeric command phases, the latest
result/rejection and the first anomalous response. Normal diagnostic retrieval
exports those numbers after a helper/app restart. This diagnoses the build-26
attach-to-ready gap without recording packet contents, remote field names,
registers, errors, process identifiers or secrets. Existing receipts without
these optional members still decode. Telemetry cannot establish readiness or
replace any owned-operation, ACK, restoration or execution proof.

Command phases are 0 (script setup), 1 (attach), 2 (ignored exceptions), 3 (pass
signals), 4 (continue), 5 (signal vCont), 6 (signal fallback), 8 (instruction
read), 10 (existing fault kill), 12 (PC ACK), 13 (legacy zero-register ACK),
14 (detach ACK), 15 (page preparation), and 16 (preparation return ACK).
Codes are 0 (command entered), 1 (reply returned), 2 (SDK command threw),
3 (non-string stop), 4 (stop over 2048 characters), 5 (stop header),
6 (unterminated stop), 7 (no fields), 8 (field syntax), 9 (duplicate field),
10 (thread syntax), 11 (foreign thread process), 12 (process mismatch/syntax),
13 (fork/vfork), 14 (exception type syntax), 15 (missing required register),
16 (register width), 17 (PC alignment/range), 18 (ACK refusal), 19 (foreign BRK),
20 (unknown owned command), 21 (ambiguous page reply), 22 (refused extent),
23 (definitive page error), 24 (empty command reply), 25 (optional setup
non-OK reply), 26 (script exception), 29 (SDK returned without owned detach),
and 30 (SDK returned unclean without a typed rejection). Optional setup replies
remain best-effort. Length is capped at 65535 JavaScript UTF-16 code units;
field count is capped at 255 separators within the first 2048 characters.
The 1072-page ACK loop records one entry per arena and anomalies only. Normal
checkpoints stop after 96 records; one anomaly per fixed command phase and the
terminal reason remain available. Exhausting that budget changes no command.

LLVM debugserver emits one `memory:` field per expedited stack chunk in
`AppendExpeditedMemoryToStopReply` and requests up to two chunks for stop replies.
The PSP validator now permits this repeated field, validates each bounded
`0x<address>=<whole hex bytes>` shape and otherwise ignores the data. It never
uses expedited memory as an arena, register, instruction or ownership proof.

The version-2 native interface also exposes additive diagnostic preparation and
restoration entry points. Fixed records identify identity rejections and each
arena's allocation, remap, protection, region query, wire range, overlap, helper
return, sentinel and coherence failure. Syscall records preserve the immediate
errno or Mach result; they contain no arena address or bytes. Region checks
accept a containing coalesced VM region only when its complete information,
exact protection and overflow-safe extent cover the entire owned view. A local
Mach fixture reproduces the original exact-start rejection; this does not
establish the cause of a phone failure. Restoration checks and their journal
writes run on the retained preflight worker. Required journal failure still
refuses JIT.

An optional typed helper failure record retains the preparation sequence,
fixed reason and complete `Ehh` reply's numeric byte through detach and SDK
completion. It survives an earlier optional setup warning and normal app export.
It is informational and changes no command, ownership or exception policy.

The shared control model adds optional per-button opacity, defaulting to the
previous appearance for old layouts and presets. The editor saves this value
for Windows and per-game console layouts. Alpha affects the visual face while
native touch surfaces and editor handles retain their existing hit behavior;
pressed feedback remains visible. Console scope changes are observed when
refreshing the Windows touch registration, including restored layouts with the
same control IDs. Controller availability is refreshed on app activation using
the existing observer, without replacing upstream input handlers.

PSP arena records retain
both full protection masks at allocation/remap/protect/helper/restoration
checkpoints. A permission mismatch continues to refuse JIT.
The mandatory region query proves the complete owned view across at most 1024
contiguous regions, checking exact permissions and complete replies at each
step. A split allocation is accepted only after its entire range is covered;
holes, zero progress, overflow, short replies and mismatched permissions fail.
Rejection flags describe the failing cursor and remaining span. This changes no
allocation ownership, protection request, helper command or execution gate.
All other duplicate restrictions remain. This corrects a reproducible valid
protocol rejection consistent with the build-27 duplicate-field receipt; the
saved numeric receipt does not establish which actual field was duplicated.
See the [upstream producer](https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/RNBRemote.cpp#L2557).

New numeric duplicate categories are 31 (thread), 32 (thread list), 33 (process),
34 (exception type), 35 (required registers), 36 (other register), and 37 (other
metadata). Code 38 refuses malformed expedited-memory metadata. Code 9 remains
valid for older receipts. These records contain no remote key, address or bytes.
