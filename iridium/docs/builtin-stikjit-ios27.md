# JIT setup

JIT lets an engine run translated code. Madeira, PSP, Dolphin, and Azahar share
one coordinator and provider selection. Each engine checks its own memory path.
Dolphin and Azahar require JIT; PSP can fall back to its interpreter.

## Standalone app

1. Sign Iridium and its helper extension with debugging permission (`get-task-allow`).
2. Import a valid remote-pairing file in **Settings → Launch Support**.
3. Connect LocalDevVPN and start the game.

The app targets iOS 18+. Built-in JIT requires iOS 26+; use an external JIT
provider in Launch Support on earlier supported systems. A debugger attachment
alone is insufficient on devices that require executable-region preparation.

Verify increased-memory-limit in the final app signature and provisioning
profile. The packaged anonymous carrier grants no installation or memory rights.
Pairing files stay protected and excluded from backups; do not share them in logs.

## LiveContainer

Use the external JIT route in Launch Support. Automatic tries LiveContainer2,
StikDebug, LiveContainer, then a LiveContainer3 fallback. The built-in extension
requires standalone installation. Hosted execution uses the container's rights.

## Recovery

Follow the app's pairing, VPN, permission, or restart error. Do not force-stop a
helper that can own a stopped app thread. Shared cleanup waits for its owned
helper, debugger release, and network restoration. Uncertain cleanup requires
an app restart before another launch.

For build and package checks, use the [build guide](../../docs/actions-ipa.md).
Device tests must cover game execution, resume, close, and another launch.
Retain the [StikJIT notices](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
