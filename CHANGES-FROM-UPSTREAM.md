# Changes from upstream

Source snapshot and privacy edits: 2026-09-10. Existing notices are retained. This is a modified source distribution.

Iridium app changes include Madeira runtime integration, JIT helper support, media and input integration, and library/navigation changes. Legacy runtime forks include the Iridium iOS bridge and build support. The upstream records below identify base revisions; they do not assert a byte-identical copy.

## testrepos/Madeira
Upstream: https://github.com/willfaust/Madeira
Base revision: `97e2ce26e6dc9e4a38976f3b5deb9272d64558eb`

Local modified source paths included in this snapshot:
- `app/Madeira/ContentView.swift`
- `app/Madeira/StikJITHelper.swift`
- `app/Madeira/WineProcessBridge.m`
- `build/ntdll-unix/build.sh`
- `build/wineserver/build.sh`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/FEX
Upstream: https://github.com/willfaust/FEX
Base revision: `053c385ecc9090702e4959a1d96752ea918a6110`

Local modified source paths included in this snapshot:
- `FEXCore/Source/Interface/Core/Core.cpp`
- `FEXCore/Source/Utils/ArchHelpers/Arm64.cpp`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/wine
Upstream: https://github.com/willfaust/wine
Base revision: `7817e220384e895651f868ba4d97affcf21b3816`

Local modified source paths included in this snapshot:
- `dlls/ntdll/loader.c`: restrict the JIT alias lifecycle diagnostic to ARM64EC, where its helper is defined; preserve the ARM64EC diagnostic.
- `dlls/win32u/dibdrv/bitblt.c`: restrict iOS source-bitmap debug hooks to `WINE_IOS` builds so desktop Wine links without iOS app symbols.

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/research/dxmt
Upstream: https://github.com/willfaust/dxmt
Base revision: `b4b89f0a5a1752da3982a7b6c5575506024bf253`

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

- GStreamer 1.28.6 applemedia: test whether the selected target can use
  AssetsLibrary before compiling and registering iosassetsrc. Keep AVFoundation
  and VideoToolbox elements enabled. The Cerbero recipe and source patch are
  retained in `ci/patches/cerbero-assets-library.patch` and included by the
  existing Cerbero source-bundle mechanism.
