# JIT Setup

Windows, GameCube/Wii, 3DS, PS2, Dreamcast, and arcade games need JIT.
PSP can use JIT or its interpreter. GB/GBC do not need JIT.

## Standalone with the built-in helper

1. Sign Iridium and its helper extension with debugging permission (`get-task-allow`).
2. Open **Settings → JIT & Memory → JIT Setup** and choose **Automatic** or
   **Built-in StikJIT**. Import this device’s pairing file there or through Add Game.
3. Connect LocalDevVPN and start the game.

The app and helper target iOS 18 or later. On iOS 27 or later, you can also
pair inside Iridium and use the optional LocalDevVPN Shortcut.

StikDebug can attach a debugger when the built-in helper is unavailable. Shared
JIT memory preparation requires the built-in helper.

Verify increased-memory-limit in the final app signature and provisioning
profile. The packaged anonymous carrier grants no installation or memory rights.
Pairing files stay protected and excluded from backups; do not share them in logs.

Windows and console memory prepare separately. JIT & Memory shows which pools
are prepared. You can prepare console memory there. Windows memory prepares
when you start a Windows game. The pools persist until Iridium exits.
The [checked transport](../apps/ios/JITSupport/README.md) reduces debugger requests
during preparation.

## LiveContainer

Use the external JIT route in JIT Setup. Automatic tries LiveContainer2,
StikDebug, LiveContainer, then a LiveContainer3 fallback. The built-in extension
requires standalone installation. Hosted execution uses the container's rights.
External debugger attachment alone cannot replace the owned helper required by
Iridium's shared-memory preparation.

## Recovery

Follow the app's pairing, VPN, permission, or restart error. Do not force-stop a
helper that can own a stopped app thread. Shared cleanup waits for its owned
helper, debugger release, and network restoration. Uncertain cleanup requires
an app restart before another launch.

For build and package checks, use the [build guide](../../docs/actions-ipa.md).
Device tests must cover game execution, resume, close, and another launch.
Retain the [StikJIT notices](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
