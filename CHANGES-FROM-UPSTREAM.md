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
- No tracked source changes.

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.

## testrepos/Madeira/research/dxmt
Upstream: https://github.com/willfaust/dxmt
Base revision: `b4b89f0a5a1752da3982a7b6c5575506024bf253`

Local modified source paths included in this snapshot:
- `src/airconv/shaders/air_tessellation.metal`

Generated artifacts, personal paths, device identifiers, and local captures were excluded or sanitized where applicable.
