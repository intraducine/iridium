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

## Results

Record steps, observations, failures, and untested paths. Source tests, builds,
simulator checks, and device runs establish different facts. A running status,
allocator probe, or open player does not establish gameplay.

Keep raw logs and private identifiers outside public reports. Use
[the release process](../../docs/releasing.md) for release evidence.
