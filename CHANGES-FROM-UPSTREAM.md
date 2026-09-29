# Changes from upstream

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
- `WineServerBridge.m`: publish atomic liveness and clear it on thread cleanup, including fatal startup exits. No forced thread cancellation is added.


Source snapshot and privacy edits: 2026-09-10. Existing notices are retained. This is a modified source distribution.

Iridium app changes include Madeira runtime integration, JIT helper support, media and input integration, and library/navigation changes. Legacy runtime forks include the Iridium iOS bridge and build support. The upstream records below identify base revisions; they do not assert a byte-identical copy.

## testrepos/Madeira
Upstream: https://github.com/willfaust/Madeira
Base revision: `8c050d03f4d89096e1e2e2c8bb44479fffd86619`

Local modified source paths included in this snapshot:
- `app/Madeira/ContentView.swift`
- `app/Madeira/StikJITHelper.swift`
- `app/Madeira/WineProcessBridge.m`
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
- StikJIT's fetched prebuilt FFI archive is excluded from linking. Its replacement is built from a documented source revision; compatibility remains untested.
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
