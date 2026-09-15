# Preserve game data and confirm runtime shutdown

## Decision

Imports and relocation create unique, validated copies. The prior installation
is never removed as part of copying. A failed copy raises an error and does not
register the source path as a successful managed import. Old copies are retained;
they consume storage and must not be automatically pruned because they may hold saves.

Version-zero library snapshots are backed up and migrated in place, preserving
records and managed game files. The format version is not bumped by these fixes.

The isolated Madeira game copy records SHA-256 fingerprints of its source files.
When source files change, updates are prepared in a staging copy. Files modified
only by the guest are preserved; conflicting source/guest changes require an
explicit Refresh Game Copy confirmation. A complete previous isolated copy is
retained in a game-backup-UUID directory. A journal permits recovery when an app
termination interrupts a directory swap. Windows profile saves outside the game
copy are never replaced by this refresh. File/directory type conflicts are rejected.

Launch arguments use a bounded JSON array instead of whitespace tokenization.
Startup errors reach one terminal failure callback. The process remains
single-session after native/JIT initialization, including cancellation and failure.
Close Game asks the guest to exit and waits for root-process and server liveness
to clear. An eight-second timeout leaves the player available and reports that
shutdown is unconfirmed. No forced thread cancellation or runtime reinitialization
is attempted. A late exit is still monitored.

The manual device keyboard changes only the presentation rectangle. Its input
focus and the mouse-lock request are separate. US-layout ASCII is the current
text contract; an unsupported insertion is rejected as a whole and reported,
never silently converted. The direct native per-keystroke diagnostic is removed.

## Alternatives

Deleting an old import before copying, discarding old snapshots, unconditionally
replacing isolated files, or treating Alt+F4 delivery as proof of exit were rejected
because they can lose data or report success without completing the operation.
Changing the guest framebuffer to fit a keyboard was rejected; presentation scaling
is sufficient and preserves the selected render resolution.

## Recovery and rollback

Retain source imports and game-backup directories until saves have been verified.
The pre-migration JSON is kept next to state.json. Restore files only while the app
and runtime are stopped. Do not delete an update journal or its referenced backup
while a swap is unresolved. Reverting the code does not remove these backups, but
old versions cannot interpret the new game-copy update manifest and may use an old
copy. Restart the app between runtime sessions.

## Evidence required before merging

Run the repository source checks, core tests, and Madeira integration checks.
Build with the selected iOS SDK. Test standalone and LiveContainer on-device:
copy failure, migrated library, game update, save persistence, startup cancellation,
process exit, unresponsive close, keyboard/menu focus, Backspace, pointer mapping,
rotation, and floating/docked iPad keyboards. Portable stub tests are not a
substitute for the actual runtime or UIKit checks.
