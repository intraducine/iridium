# Set up JIT

Windows, GameCube, Wii, 3DS, PS2, Dreamcast, and arcade games need JIT.
PSP can use JIT or its interpreter. Game Boy and Game Boy Color do not need JIT.

## Standalone Iridium

1. Sign Iridium and its JIT helper with debugging permission
   (`get-task-allow`). For extended memory, include the increased memory entitlement in
   the app’s signing profile and final signature.
2. Open **Settings → JIT & Memory → JIT Setup**. Choose **Automatic** or
   **Built-in StikJIT**. Import a pairing file made for this device. On iOS 27 or
   later, **Pair in Iridium** can create one for you.
3. Connect LocalDevVPN and start the game. On iOS 27 or later, you can also use
   the optional VPN Shortcut in JIT Setup.

**JIT & Memory** shows which memory pools are prepared. Use
**Prepare Console JIT** to prepare console memory before launch. Windows
prepares its memory when you start a Windows game. The prepared memory lasts
until Iridium closes.

## LiveContainer

Select **LiveContainer** in **JIT Setup** and follow the steps there to set up
StikDebug and save the JIT script. Connect LocalDevVPN, then close Iridium and
reopen it from LiveContainer.

LiveContainer supplies the signing permissions for hosted apps. Iridium’s
built-in helper requires a standalone installation. StikDebug can attach a
debugger, but a debugger attachment alone cannot prepare Iridium’s shared
memory pools.

## If JIT fails

Follow the recovery message in the app. Check the pairing file, LocalDevVPN,
and the permissions on the installed app. If cleanup fails and Iridium asks
you to restart, close and reopen the app before launching another game. Do not
force-close the helper while setup is running. Keep pairing files private.
