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
  uses pinned RGBDS; the unchanged Libretro adapter accepts a 96 kHz target.
- **Dolphin:** upstream iOS/Metal integration with strict floating-point flags,
  checked executable-memory preparation, ordinary ownership for non-executable
  blocks, and no cached-interpreter fallback. CoreAudio sample gain provides mute
  and disposes its audio unit on stop. Generated hooks correct state-load success,
  simulator framebuffer fetch, bundled dependency flags, and Apple Clang compatibility.
  Iridium supplies controller profiles, state slots, WAD backup/recovery, and Sys data.
- **Azahar:** verified official unified source; Oaknut/Dynarmic/shader overlays use
  separate writable/executable aliases and checked cache updates through shared
  JIT. Generated locks initialize after callback registration. Checked-memory mode
  preserves debugger exception handlers. The main Vulkan renderer uses an iOS
  Metal surface and source-built MoltenVK 1.4.1. Libretro retains input/audio/saves.
- **Play!:** per-game configuration, checked CodeGen protection results, executable
  probe, and upstream VM pause with GS mailbox draining.
- **Flycast:** generated ES3 capability, executable probe, upstream VM stop/resume,
  and nonvolatile-storage flush.

## Native PPSSPP

The v1.20.4 iOS player replaces the historical Libretro/software player. Generated
hooks adapt app/window ownership, input, callbacks, settings, managed memory sticks,
media checks, sensors, picker lifetime, renderer drain, and main-thread teardown.
Iridium owns controls and menus; upstream CPU/HLE/GPU/save algorithms remain.

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
