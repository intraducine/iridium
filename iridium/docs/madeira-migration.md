# Madeira runtime integration

Madeira is selected by the current `apps/ios/stikjit.yml` app build. This document
retains the source trace and earlier migration criteria; use the root
[IPA guide](../../docs/actions-ipa.md) for preparation and the
[manual runbook](manual-validation-runbook.md) for release-specific acceptance.
The integrated runtime now includes i386 Wine/FEX WoW64, D3D9, and D3D12 build
inputs; their presence is not a compatibility guarantee for every game.

## Source trace

Madeira README describes one Mach process, native iOS Wine unix libraries,
ARM64EC Wine PE modules, FEX x64 translation, and DXMT D3D11-to-Metal rendering.
The checked-out source supports that description:

- `app/Madeira/ContentView.swift:runWineFullSequence` allocates the shared JIT
  pool, publishes its RX/RW addresses, detaches, starts wineserver, then Wine.
- `StikJITHelper.swift:allocatePool` preserves placement constraints and creates
  the writable alias. The external JIT route is selected in Launch Support.
  Automatic tries LiveContainer2, StikDebug, LiveContainer, then a LiveContainer3 fallback.
- `WineServerBridge.m` starts the native server thread. `WineProcessBridge.m`
  supplies a socketpair, prepares the prefix and loads the native Wine entry.
- `build/ntdll-unix/build.sh` links native loader, memory, signal and thread
  implementations. This does not run Linux ntdll through Iridium's syscall bridge.
- The fork's ARM64EC `xtajit64.dll` supplies production translation.
  `FEXBridge.mm` is a separate native smoke-test harness, not part of this path.
  The adapter provides its two required pool/cache utilities in `NativePool.c`.
- `IOSDisplayShim.m` exposes the UIKit-owned Metal layer to DXMT.
- `Winios/Winios.m` provides windowing and queued mouse/key events.
- `WineProcessBridge.m` activates AVAudioSession. The native
  `build/ntdll-unix/audio_null_ios.c` now includes a RemoteIO backend; its filename
  and older build-script comments alone do not establish whether audio works.
- `wine_process_is_running` is a lifecycle signal, not rendered-frame proof.
  DXMT exposes `madeira_get_present_count` for actual present calls.

The integration uses this native component set and startup sequence through
an adapter for Iridium's player. Use separate prefixes for migration tests.

## License notices

Madeira's application code is GPL-3.0-or-later. The currently integrated Wine
source is its rebuilt `madeira-lgpl` branch under LGPL-2.1-or-later, as recorded
in `testrepos/Madeira/wine/LICENSE-MADEIRA.md`; the earlier branch's LGPL-to-GPL
conversion does not apply to this source. FEX and DXMT retain upstream MIT notices
with Madeira modifications under GPL-3.0-or-later. The imported D3D9/DXSO frontend
retains LGPL-2.1-or-later. The rpmalloc fork retains 0BSD upstream terms and
separately identifies GPL modifications. See the root [license guide](../../LICENSING.md)
for component boundaries and the adopted converter exception's scope.

Preserve Madeira's LICENSE, THIRD-PARTY-NOTICES.md, LICENSES directory, and
fork-specific LICENSE-MADEIRA.md notices with reused code. Mark adapter changes
and retain copyright attribution. A distributed combined derivative requires
GPL-compatible terms and corresponding source, including build/install scripts;
credit alone is insufficient. Follow the repository release policy before distribution.

Microsoft runtime DLLs and games are separate inputs. Do not claim that Madeira's
license grants redistribution rights to them. See its tools/fetch-vcruntime.md.

## Acceptance

1. Build with Xcode 27 through `stikjit.yml`, audit the sideloading package, and
   verify the recipient's final signed bundle and profile before device tests.
2. Launch the x64 DX11 cube inside Iridium with the complete Madeira runtime.
3. Verify changing rendered frames and input response.
4. Launch Hollow Knight in a separate prefix; verify menu, sound, gameplay,
   shutdown, and save persistence across a fresh process.
5. Record these results for the selected source/build/device before claiming
   release compatibility. The build's runtime selection alone is not acceptance.

Opening the player, a running status, or a successful build is not acceptance.

## Controller integration

Controller support uses an XInput bridge. The host snapshots
up to four extended GameController devices at 60 Hz, writes changed state
atomically inside the isolated prefix, and supplies x86/x64 XInput DLLs beside
the isolated executable. Game-supplied DLLs are backed up there before replacement.
Original game files remain untouched. Rebuild these DLLs with
`apps/ios/Scripts/build_controller_runtime.sh` before the app build.

Both sticks, analog triggers, D-pad, face/shoulder/stick buttons and menu/options
are forwarded as controller state. Player slots remain stable across enumeration
changes. Rumble, audio device APIs, XInput keystroke events, DirectInput/HID-only
games and micro-gamepads are not implemented. Test packet boundaries, analog input, and disconnects with the controller
runtime checks, then verify input in the selected game.
