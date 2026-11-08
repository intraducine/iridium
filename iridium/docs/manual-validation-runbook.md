# Device testing

Test the exact build on the intended device. Use owned game files and authorized
accounts. Preserve existing games and saves.

## Before testing

- Record commit, build/run, app/helper versions, device model, OS, and game/version.
- Check the package, recipient signature/profile, installed entitlements, and [JIT setup](builtin-stikjit-ios27.md).
- Name the input method. Separate standalone and LiveContainer results.

## Game session

1. Import through the normal UI and launch from the library.
2. Verify changing frames and input response. Check touch, keyboard/mouse, and controller separately.
3. Check audible output, mute, pause, background/resume, and orientation.
4. Save, close, relaunch, and load the save. Repeat after restarting the app.
5. Confirm teardown returns to the library, restores input/haptics, releases owned
   JIT, and restores networking. Launch a second game without restarting where supported.
6. Test cancellation, a failed launch, reconnects, and any required restart path.

To measure JIT setup, start with JIT disabled after an app restart. Record debugger
attach, Windows preparation, console preparation, native start, and first frame
separately. A Windows-first launch must not prepare the console arena. Then launch
a JIT console, Windows again, and the same game twice. Check each engine's memory
probe, request ownership, cleanup, and failure recovery. Compare the same game and
device state; fewer debugger requests alone do not prove a faster first frame.

For installers, verify prompts, recorded success, cancellation, and late exit.
For downloads, test authentication, account changes, storage warnings, network
loss, resume, verification, and repair while retaining old files. Test Cloud
conflicts/backups separately when supported by the selected implementation.

## Interface

Use empty and populated libraries, long titles, and custom/missing artwork.
Check portrait/landscape, first/last covers, search with keyboard, repeated menus,
touch/controller handoff, VoiceOver, large text, contrast, and reduced motion.
Controls and text must clear safe areas and clipping edges. Content must remain
visible if animation does not run.

Rotate during cold Windows JIT preparation and native loading. Confirm the stage,
timer, live RAM bar, and controls keep updating. Close to the library and check
that no keyboard, controller, or editor controls remain there. Check the first
and last covers at high swipe speed and the selected cover's alignment in both
orientations.

Test uninstall from each store, a whole folder removed in Files, partial damage,
and a disconnected external drive separately. Confirm repair appears only where
supported and a missing install cannot offer Play. Test bulk game/archive/pairing
imports and installed CIA storage without changing existing saves. Check setup
completion after an update and a physical reinstall as separate cases.

## Results

Record steps, observations, failures, and untested paths. Source tests, builds,
simulator checks, and device runs establish different facts. A running status,
allocator probe, or open player does not establish gameplay.

Keep raw logs and private identifiers outside public reports. Use
[the release process](../../docs/releasing.md) for release evidence.
