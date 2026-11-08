# JIT Setup

Windows, GameCube/Wii, 3DS, PS2, Dreamcast, and arcade games need JIT.
PSP can use JIT or its interpreter. GB/GBC do not need JIT.

## Standalone app

1. Sign Iridium and its helper extension with debugging permission (`get-task-allow`).
2. Open **Settings → JIT & Memory → JIT Setup** and select **Built-in StikJIT**.
   Import a valid remote-pairing file there or through Add Game.
3. Connect LocalDevVPN and start the game.

The app and built-in JIT helper now target iOS 18 or later. This requires a new
IPA. On iOS 18, use a pairing file made on a computer and connect LocalDevVPN
manually. On-device pairing and the VPN shortcut require iOS 27 or later.

The built-in helper prepares Iridium's executable memory before launch.
An external debugger attachment alone cannot prepare the shared memory pools.

Verify increased-memory-limit in the final app signature and provisioning
profile. The packaged anonymous carrier grants no installation or memory rights.
Pairing files stay protected and excluded from backups; do not share them in logs.

Windows and console memory are prepared separately, only when requested. Later
games reuse that memory until the app exits. The UI shows progress and elapsed
time. A first launch or memory growth can still wait. The
[checked transport](../apps/ios/JITSupport/README.md) reduces debugger requests;
new startup times need device tests.

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
