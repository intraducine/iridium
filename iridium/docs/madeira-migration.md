# Madeira runtime migration

Status: inspection and integration in progress. No device success claimed.

## Preserved baseline

The existing Linux runtime remains available. Existing repository edits were
recorded in `/tmp/iridium-madeira-migration-baseline` before migration edits.
No app, prefix, save, or repository was deleted or reset.

## Source trace

Madeira README describes one Mach process, native iOS Wine unix libraries,
ARM64EC Wine PE modules, FEX x64 translation, and DXMT D3D11-to-Metal rendering.
The checked-out source supports that description:

- `app/Madeira/ContentView.swift:runWineFullSequence` allocates the shared JIT
  pool, publishes its RX/RW addresses, detaches, starts wineserver, then Wine.
- `StikJITHelper.swift:allocatePool` preserves placement constraints and creates
  the writable alias. Its current local URL fallback uses LiveContainer2.
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

The integration will reuse this complete native component set and sequence,
with an adapter for Iridium's player. Test prefixes must be separate from the
existing prefixes. Default selection stays unchanged until device acceptance.

## License notices

Madeira's current application code is GPL-3.0-or-later. Its Wine fork carries
an LGPL-to-GPL conversion notice; FEX and DXMT retain upstream MIT notices
with Madeira modifications under GPL-3.0-or-later. The rpmalloc fork retains
0BSD upstream terms and separately identifies GPL modifications.

Preserve Madeira's LICENSE, THIRD-PARTY-NOTICES.md, LICENSES directory, and
fork-specific LICENSE-MADEIRA.md notices with reused code. Mark adapter changes
and retain copyright attribution. A distributed combined derivative requires
GPL-compatible terms and corresponding source, including build/install scripts;
credit alone is insufficient. This private integration does not change Iridium's
top-level license or authorize distribution. Do not publish or push it.

Microsoft runtime DLLs and games are separate inputs. Do not claim that Madeira's
license grants redistribution rights to them. See its tools/fetch-vcruntime.md.

## Acceptance

1. Build with Xcode 27 and verify the final signed bundle.
2. Launch the x64 DX11 cube inside Iridium with the complete Madeira runtime.
3. Verify changing rendered frames and input response.
4. Launch Hollow Knight in a separate prefix; verify menu, sound, gameplay,
   shutdown, and save persistence across a fresh process.
5. Only after those checks pass, switch the default runtime.

Opening the player, a running status, or a successful build is not acceptance.

## Device evidence, September 8

The integrated app built, passed final signature verification and installed.
The isolated-copy check passed; 47 existing app-support tests passed.
Explicit test selection and pending title now survive StikDebug relaunches.
Old JIT readiness probes are bypassed in the experimental runtime.

The latest captured cube launch (`/tmp/iridium-madeira-current4.log`) reached
the original 896 MB pool allocation, writable alias, debugger detach,
wineserver and `C:\windows\system32\cube-x64.exe` through ARM64EC Wine.
FEX then reported `ml755 FATAL: no FEX arena`; there is no rendered-frame proof.
This is a memory placement failure after successful JIT setup.

The saved signed Madeira app and its provisioning profile both include
Increased Memory Limit. The first integrated Iridium build omitted it.
The migration target now requests this same permission. Extended Virtual
Addressing is not required by the saved Madeira artifact and is not requested.
The corrected build passed the entitlement/signature check and installed.
After unlocking and enabling JIT, the corrected build launched the cube.
The user confirmed a visible cube. `/tmp/iridium-madeira-cube-visible.log`
records the cube executable, a 512 GB maximum address (previously 454 GB),
successful FEX band selection at `0x7c00000000`, and advancing DXMT sequences
(1263 at capture). This establishes the first runtime launch milestone.
Menu/gameplay/audio/save acceptance remains separate and unverified.

The old project remains available. The experimental selection is explicit:
`IRIDIUM_RUNTIME=madeira`, `IRIDIUM_MADEIRA_TEST=cube` (or `game`), and
`IRIDIUM_DEBUG_LAUNCH_TITLE=hollow_knight`. These settings persist for test
relaunches; `IRIDIUM_RUNTIME=legacy` restores the old selection.
Hollow Knight, audio, input, gameplay, orderly shutdown and device save
persistence are not yet verified. The default has not been promoted.

## Controller integration

The user subsequently confirmed the Hollow Knight menu. Controller support is
now an XInput bridge, not Hollow Knight keyboard bindings. The host snapshots
up to four extended GameController devices at 60 Hz, writes changed state
atomically inside the isolated prefix, and supplies x86/x64 XInput DLLs beside
the isolated executable. Game-supplied DLLs are backed up there before replacement.
Original game files remain untouched. Rebuild these DLLs with
`apps/ios/Scripts/build_controller_runtime.sh` before the app build.

Both sticks, analog triggers, D-pad, face/shoulder/stick buttons and menu/options
are forwarded as controller state. Player slots remain stable across enumeration
changes. Rumble, audio device APIs, XInput keystroke events, DirectInput/HID-only
games and micro-gamepads are not implemented. Packet boundary/analog/disconnect
checks and the Xcode build pass; device controller response is still pending.
