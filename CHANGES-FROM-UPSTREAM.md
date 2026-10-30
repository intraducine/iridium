# Changes from upstream

This is a modified source distribution. Original notices remain in each
component. [UPSTREAM-SOURCES.json](UPSTREAM-SOURCES.json) records base revisions
and ported commits; build recipes and receipts record generated adaptations.

## App and Madeira

The maintained app includes Madeira-derived sources with import hashes and
licenses in `iridium/apps/ios/App/source-ownership.json` and `App/Origin`.
Iridium owns its library, artwork, navigation, setup, controls, settings, and
runtime adapters. Frozen build-43 overlays remain test fixtures only.

Adaptations include:

- Shared player/input ownership, isolated console records, Favorites, artwork,
  import validation, and save-safe import of older libraries.
- JSON launch arguments, atomic process/server liveness, startup readiness,
  profile-path repair without overwriting saves, and prerequisite installer flow.
- Touch/controller/keyboard routing, installer desktop presentation, frame counters,
  and removal of per-keystroke logging.
- A saved global sync choice with atomic configuration updates and restart checks.
- Native iOS Wine packaging without the legacy Linux userland or host executable.
- Source-built native/i386 dependencies, fail-on-error compilation, checked
  completion records, architecture validation, and independent component reuse.

The native recipes reconstruct wineserver archives, configure FEX for arm64,
adapt LLVM 15 Darwin checks for iOS, and adapt the tessellation shader's atomic
operation. Existing sources/notices are retained with these build recipes.
ARM64EC callbacks tolerate missing CPU areas on native startup threads, before
the emulator initializes their thread state. Native ARM64 children in an x64
session load their own native ntdll instead of inheriting the ARM64EC loader.

The Madeira update through `e3a88fddb8daed1f5ac28a45dcb4663d65192629`
retains the native memory, process, synchronization, audio, archive and input
fixes. Its Swift changes are applied to the maintained app sources. The shared
JIT coordinator still owns debugger access and cleanup; Madeira retains its
executable-window sizing and code-pool allocation. The updated native contract
includes the window-caption field used by the startup window census.

Steam Cloud cache records, download languages, clipboard input, mouse-wheel
mapping, touch-control locking and gesture zones retain their upstream behavior.
Windows gesture zones also participate in Iridium's saved control profiles and
editor restoration, with platform and geometry validation. Per-game zones do
not replace the global working layout. Iridium keeps its own library and
navigation; the upstream zoomable grid is not included. Windows launch content
stays visible when an animation is interrupted or disabled. Gesture-zone options
fit their content and scroll when the available height is too small.
Steam WebSocket setup and logon share a single-completion guard. Repeated ping
callbacks cannot resume a continuation twice, and a retired socket cannot start
receiving after a later disconnect or replacement.
The generated Metal adapter records owned graphics references by guest process
and session. After guest kernel threads end, it drains completed processes'
submitted GPU work before releasing their remaining references or private memory.
Live, unknown and shared references retain their normal lifetime. A failed or
timed-out GPU drain keeps the old references and mappings in place.
The native shader adapter fills unwritten vertex-output lanes and replaces
non-finite floating-point interpolants with zero. Metal cannot safely interpolate
NaN or infinity. Integer outputs, pixel outputs and position handling keep their
upstream paths. The adapter checks the pinned signature and build recipe.

### Selected compatibility ports

The `ported_changes` records identify the exact source and follow-up commits.

| Upstream Madeira change | Adaptation |
| --- | --- |
| #107 | Eligible anonymous RWX data heaps use host memory; disable with `MADEIRA_GUEST_RWX_DATA=0` |
| #110 | Unaligned shared PE sections use private contents; disable with `MADEIRA_SHARED_SECTION_PRIVATE=0` |
| #111 | Stripped-relocation images can use the executable window below 64 MB; disable with `MADEIRA_EXE_WINDOW_SMALL_FIXED=0` |
| #119 | D3D12 color resolves, compatible stand-ins, and resize/format replacement; depth/region resolves remain unsupported |
| #120 | Native IL-only child machine selection without an i386 guest window |
| #125 | Registry-complete server readiness, cancellable 30-second wait, and fatal-thread cleanup; `MADEIRA_FAST_SERVER_START=0` adds the old minimum delay |
| #129 | Metal 3.1 shader targets and cache invalidation with iOS native AIR targets retained |

Authors include JesseLovelace (#107/#119/#120/#125), 125hz (#110/#111 and DXMT
shader pins), and Will Faust (follow-ups and native shader adapter). The controller
keyboard/mouse mapper adapts Madeira #128 and
`6722178dd9b93898b812ae9be6130565d92652fc`, retaining GPL-3.0-or-later and the
Madeira Converter Exception. Iridium supports all four existing controller slots.

Prerequisite parsing adapts `DockInstallers.swift` at
`40d5e74848e4ee7060e879c07ef74487d9dc8cec`; `prerequisites.c` adapts
`madeira-dock/src/scm.c` at `3cadfbea700e4da4b04e331dd7ef1ba633dfacef`.
These retain 125hz's copyright, GPL-3.0-or-later, and the Converter Exception.

## Console engines

Engines retain their upstream CPU/GPU implementations behind isolated native
interfaces. [Console documentation](docs/console-engines.md) lists build entries.

- **SameBoy:** private symbol namespace, generated replacement boot data, bounded
  frame/audio/input delivery, and per-game battery/RTC storage. Boot generation
  uses pinned RGBDS; the pinned Libretro adapter accepts a 96 kHz target.
  The app exposes core options, version-checked state slots, bounded rewind,
  and 2× speed with muted audio. A checked generated adapter enables upstream
  GameShark/Game Genie parsing. It validates a replacement set before changing
  live codes.
- **Dolphin:** upstream iOS/Metal integration with strict floating-point flags,
  checked executable-memory preparation, ordinary ownership for non-executable
  blocks, and no cached-interpreter fallback. CoreAudio sample gain provides mute
  and disposes its audio unit on stop. Generated hooks correct state-load success,
  simulator framebuffer fetch, bundled dependency flags, and Apple Clang compatibility.
  Iridium supplies controller profiles, state slots, WAD backup/recovery, and Sys data.
  Additional typed graphics/compatibility settings use an optional command interface.
  The command interface also changes disc images and edits per-game OnFrame
  patches through upstream parsing and atomic INI saving. Built-in patch code
  stays immutable. Patch reload restores Iridium-managed cheats.
- **Azahar:** verified official unified source; Oaknut/Dynarmic/shader overlays use
  separate writable/executable aliases and checked cache updates through shared
  JIT. Generated locks initialize after callback registration. Checked-memory mode
  preserves debugger exception handlers. The main Vulkan renderer uses an iOS
  Metal surface and source-built MoltenVK 1.4.1. Libretro retains input/audio/saves.
  Screen layout and swap settings reach the core. Pointer coordinates cover the
  selected canvas; generated input rejects taps outside the current touchscreen.
  The shared host supplies motion through the Libretro sensor interface.
  An optional camera factory uses an explicit versioned callback to host-owned
  camera frames. A locked settings snapshot fixes each frame's dimensions and
  format; concurrent capture reads share a serialized pixel buffer. The Libretro microphone interface consumes bounded 48 kHz mono
  input from the host. Capture is off by default and stops on pause/close.
  An optional CIA installer uses upstream AM validation and installation in
  staged user storage. Base-title metadata creates a library entry after safe
  publication. Add Game can create new storage without an existing 3DS entry;
  updates and DLC require an existing storage target. The AM installer uses the
  pinned upstream source without changes.
- **Play!:** per-game configuration, CodeGen allocations and block-link writes
  through shared JIT aliases, pooled executable pages for small blocks, executable
  probe, and upstream VM pause with GS mailbox draining. Teardown pauses before
  the single GS release. The generated pad adapter polls two independent ports
  and maps the full signed stick range without wrapping its negative endpoint.
  Optional disc changes run through the VM mailbox while paused and restore the
  previous media on insertion failure. Failed restoration retains runtime ownership
  and blocks resume. The GS adapter reports scaled CRT dimensions before drawing.
  State controls use upstream full-VM save/load, including VM timing, through private
  temporary files. The owner drains GS work while waiting; snapshots force graphics
  memory synchronization before the archive is written. Bounded state buffers record
  the archive length, clear unused bytes, and reject earlier incomplete snapshots.
- **Flycast:** generated ES3 capability, shared JIT aliases for SH4, ARM7 and DSP
  code, executable probe, upstream VM stop/resume, and nonvolatile-storage flush.
  The host registers international core options using its English language
  selection and configures all Flycast controller ports before the first frame.
  Supported controller choices and expansion options remain under upstream
  device ownership. The pinned miniupnpc dependency is built for network options.
  Serialization preserves the prior VM running/paused state.
  During Flycast sessions, memory faults follow upstream's iOS signal
  route while JIT breakpoints stay with the shared debugger. Shutdown restores
  the previous memory-fault route before releasing JIT.

The shared Libretro host copies option definitions, validates changed values,
exposes save states with rollback, changes disc images, polls separate
controller ports, and forwards controller vibration. Optional control exports
extend the host interface without changing the required base ABI or shared JIT
memory contract. The extended disk interface supplies the actual prior image
path for rollback after a failed external disc insertion. Failed recovery retains
the runtime lease. PSP Model and Software Rendering remain staged per game until
a checked hook applies them before native CPU/GPU initialization. State writes use bounded files and atomic slot replacement.
Iridium's cheat editor uses the native SameBoy, CWCheat, Gecko/Action Replay,
and Gateway implementations. Its per-game entries preserve upstream cheat
files and existing Dolphin/Azahar entries. A generated PPSSPP hook copies its
managed codes under a mutex and reloads them on the core's cheat callback.
The OpenGL display blit restores core framebuffer/renderbuffer bindings, scissor
enable and clear color even when presentation fails. Content import/export uses
bounded staged copies with recoverable backups. Host media capture stays outside
the core and is available only through optional interfaces. Engine pins and the
shared JIT ownership contract are unchanged by these controls.

## Native PPSSPP

The v1.20.4 iOS player replaces the historical Libretro/software player. Generated
hooks adapt app/window ownership, input, callbacks, settings, managed memory sticks,
media checks, sensors, picker lifetime, renderer drain, and main-thread teardown.
Iridium owns controls and menus; upstream CPU/HLE/GPU/save algorithms remain.
Typed graphics, compatibility, shader, texture and network settings use the
upstream config fields on the render thread. JIT and backend selection remain
under the existing memory and rendering contracts.

- GL synchronization binds each readback to its completed request, cancels skipped
  work, and drains producer/render queues before teardown.
- Prepared executable memory uses a version-3 interface alongside component ABI 3.
  Four bounded arenas cover CPU (16 MiB), vertex, pixel, and sampler (256 KiB each).
  RW/RX aliases, writer/reader drain, protection, region coverage, cache publication,
  and execute/rewrite checks are required before native JIT.
- The version-2 helper protocol accepts only owned allocation sequences. Debugger
  detach acknowledgement, original SDK completion, self-task/retained-worker route
  checks, and network restoration precede execution. Unknown state retains ownership
  for restart. Interpreter fallback handles ordinary preparation failure.
- CodeBlock protection failures propagate. Emitter MOV chunk flags are initialized.
  Branch/profiler writes use checked writable views; vertex exhaustion retains
  generic decoding. No unregistered executable allocation is accepted.
- Bounded private journals record fixed stages and numeric failures. Exports redact
  addresses and secrets. Stop-reply parsing validates duplicate fields, including
  bounded repeated expedited-memory metadata. Diagnostics do not grant readiness.
- MoltenVK 1.2.9 and FFmpeg are rebuilt from locked source with link receipts.
  Four replacement atlases use licensed font inputs and preserve glyph/icon IDs.
  [Atlas adaptations](ci/psp-atlas-host/README.md) describe generation.

## Shared JIT and controls

The app owns a prepared executable-memory pool through `IRJITMemoryAPI` version 1.
Shared allocations use the process address limits, not the older PSP helper
protocol's 64 GiB wire limit. Legacy helper validation remains unchanged.
Console adapters borrow read/execute and read/write views, return their leases
only after shutdown, and keep the prepared mappings until the app exits. The
shared coordinator uses its owned built-in helper, closes it and restores the
network before starting a core. Foreign debugger connections are not adopted. Failed helper cleanup retains restart-required admission. Each core
keeps its own compiler, execution probe, library and version pin.

Dolphin's extension interface is version 2. Its TXM allocator delegates code
blocks to the shared service instead of retaining a private 512 MiB region.
Its blocks retain full-page alignment for the upstream protection calls. The
shared pool admits its 256 MiB ARM64 cache without changing legacy helper limits.
Azahar, Play and Flycast negotiate the memory service separately from the player
interface. PSP's additive shared-memory entry point retains its four bounded
arenas between clean sessions, validates their permissions, and repeats its
execution/rewrite probe. Older PSP adapters keep the owned-helper path.
Play resets its configuration and option-update state before a new VM starts.
Its teardown pauses the VM with bounded GS mailbox draining before destroying
graphics resources. A failed pause retains the runtime for an app restart.
The Madeira session adapter initializes the Windows host once and launches games
through an owned Windows job supervisor. Its versioned request/status contract is
compiled with the pinned Madeira cross compiler and audited against its source and
engine pin. Checked creation hooks track Wine guest threads with retained Mach
thread ports while preserving Wine's join/detach ownership. The app returns
admission only after job completion and guest-thread drain; retained framework
services do not block reuse. JIT setup prepares both retained Windows and reusable console arenas once;
closing a game preserves those mappings. A checked Madeira server adaptation sends
SIGQUIT through the shared task only for threads in this host process. Other
signals and debugger memory access keep their upstream behavior. Process thread
counts and deferred TEB disposal are keyed to each pseudo-process. Cleanup waits
for that process's last guest thread. Completed socket, identity and file-cache
slots are released or reused rather than imposing a lifetime session limit.
The Mach exception registry and per-thread JIT trampolines share bounded slots.
A slot can be reused only after its retained Mach port proves the previous
kernel thread ended, including TLS destructors. An unknown thread never uses
the host process's exception state. Live-slot exhaustion fails admission.
Steered memory reservations retire their tracking records when a view is deleted.
Cleanup checks the current view under the memory lock. Private views and large
reservations carry their owning process and job number. Split views retain that
ownership. Process exit retires them; admission to a later
job releases their data pages only after all prior guest kernel threads and TLS
destructors have ended. Cleanup also unmaps the dead process's original PE images;
their reusable JIT pool copies stay allocated. Live images, anonymous executable
memory, shared files, special and replaced views stay protected.
A later game can reuse an address without an old record freeing it.
Windows image copies keep their complete pool allocation after process exit.
A later job can reuse it only after the old guest threads end, no live ledger
entry overlaps it, and its code, data and trampoline pages fit the new image.
Writable pages must already be data pages. Reuse cannot remove execute access
from more pool pages. The anonymous-code allocator keeps its original checks.
Before unmapping retired private data, cleanup removes its abandoned WaitOnAddress
entries from Wine's shared queues. Live and current-job entries remain linked.
A busy queue defers reclamation. The adapter checks the pinned PE and native
queue layouts before compilation.
Native TEB cache blocks belong to the resident host even when a game's thread
causes a block to be allocated. Per-window WoW64 TEB blocks keep their process
ownership. Private-data cleanup preserves the shared cache for the next thread.
Native GDI table and 64-bit DC attribute buckets also retain host ownership.
Metal shared-event listeners retain their run loops and release their dummy
sources on thread exit. Callbacks use non-repeating registry handles instead of
capturing freed listener pointers. Retirement stops pending delivery, and a later
job releases abandoned listener registrations after the guest threads end.
The next process can reuse these shared graphics caches after game data is
released. WoW64 DC buckets retain their process-window ownership.
Each x64 child uses Madeira's existing fresh ARM64EC ntdll loader. A private
pool copy alone can inherit hooks written into the shared PE image by a prior
game. Other child architectures keep their upstream loader path.
Child startup calls win32u's existing GDI table publication helper. The shared
host initializes once, but each new process needs its own published PEB field.
The shared USER object cache records each pointer's process ID and full handle.
Recycled handles cannot expose stale pointers from a previous game.
Window procedure tables release each process's callbacks before its code is
reclaimed. New processes reuse those entries instead of filling a lifetime table.
FEX's allocation-watch diagnostic uses the host thread pointer on ARM64EC as it
already does on WoW64. It can run before Wine allocates the Windows TLS array.
The translator is rebuilt and included in the native component receipt.
No Wine registry reset is used for repeated launches. Runtime startup-only configuration retains its
upstream host-lifetime scope.
Windows preparation holds launch admission until error cleanup completes.
A missing-debugger failure releases its launch reservation only after
the shared helper confirms cleanup. A failed native initialization retains admission. Allocation errors report the
failure without terminating the app on a timer.
JIT execution checks preserve resident signal handlers' masks, alternate-stack
and restart flags. Unrelated faults keep their existing handler. One-shot and
legacy handlers remain unsupported; changed handlers are never overwritten.
Core state, rewind, cheat, patch and disc completions retain the pause intent from
their request. A later pause prevents automatic resume. Windows status polling
grants one background grace period per observed heartbeat; slow polls cannot
renew a missing heartbeat indefinitely.
Data reservations can retain read/write protection flags during cleanup.
Address ownership, job admission and special-view checks still protect live memory.
Core state files open from Foundation's app or temporary directory, so iOS does
not need to grant access to filesystem ancestors. Canonical-path and no-symlink
checks still apply to each save directory and state file.
Diagnostic exports release temporary Foundation strings after each sanitized
line instead of retaining them until the full export completes.


Per-game volume uses a shared saved gain and menu slider. SameBoy, native PSP,
Dolphin, the Libretro host, and Wine apply it to their final PCM output. Native
engine exports pass the saved gain into each retained image. Wine mixes its
streams before applying the app gain, so guest mixer settings remain intact.
Legacy Dolphin mute settings remain the default until a game volume is saved.
System and Mac output volumes are unchanged.

Madeira, PSP, Dolphin, and Azahar use the shared coordinator. The script preserves
64-bit addresses, validates page replies, and stops on SDK connection failure.
Cleanup requires the owned helper receipt, debugger release, and restored networking.
Resume reacquires required JIT before execution. Unknown debuggers are not detached.

Console touch layouts use the shared editor with per-button opacity. Native touch
targets preserve input ownership and release held states on cancellation. Moonlight
control images and touch handling retain Diego Waxemberg/Moonlight Stream's 2014
copyright and GPL-3.0 notice. Source: Moonlight iOS
`85af0f75622bb2636481afda8b0fc5cc33d5956e`, `Limelight/Input/OnScreenControls.m`.

## Retained source forks and build tools

The snapshot modifications include:

- **Madeira:** `ContentView.swift`, `StikJITHelper.swift`, native PE selection,
  signal store-pair handling, JIT bitset indexing, bounded diagnostics, input-ring
  polling, foreground notifications, and checksum-pinned converter fetching.
- **FEX:** `Core.cpp`, `Arm64.cpp`, app-reserved arena handoff, compact allocation,
  and thread failure patches.
- **Wine:** architecture-scoped sync/loader diagnostics, recursive image-map guard,
  iOS-only bitmap hooks, complete Makefile/spec inputs, and
  `arm64ec_x64_export_iat.c` from Will Faust's
  `32810bdeb4b9e72b02320e9b72ce3ba03ceee3d7` (LGPL-2.1-or-later).
- **DXMT:** `src/airconv/shaders/air_tessellation.metal` and selected ports above.
- **Cerbero/GStreamer:** gperf C++14, spandsp source mirror, AssetsLibrary capability
  checks, and complete offline source/patch/Cargo caches. Exact patches are in `ci/patches`.
- **ANGLE:** selected Apple tools and Metal-only build; sources remain unchanged.
- **idevice/StikJIT:** Cargo workspace/vendor handling, offline lockfile resolution,
  source-built FFI, textual Swift nested-type correction, and retained script notices.
- **SteamKit2:** iOS/tvOS client timestamp replaces unsupported process-start lookup.
  The retained NativeAOT integration and notices are in `iridium/packages/steam`.

Source collection includes dependency closures, generated recipes, Cargo sources,
compiler-source inputs, manifests, and notices. It omits only exact reviewed unused
signing fixtures and superseded/prebuilt assets recorded by the source receipts.
Original vendor checkouts are retained. See [LICENSING.md](LICENSING.md).
