# Product experience

Iridium's product interface is organized around one outcome: getting from a newly installed app to a first playable Windows-game session without requiring the user to understand the runtime architecture.

## Activation model

The Library derives one primary action from durable app state:

1. Repair LiveContainer integration when its folder picker or launch settings are incomplete.
2. Restart Iridium when a repair cannot affect the already-running hosted process.
3. Import a Windows game folder when the library is empty.
4. Restore external launch support when JIT or the runtime launch bridge is unavailable.
5. Resolve a game-specific compatibility blocker.
6. Play a ready game.

`ProductActivationState` owns this ordering and its user-facing copy. Views should not recreate the decision tree with independent warning banners.

## Information architecture

The root interface has three destinations:

- **Library** — setup, import, game selection, and the next action required to play.
- **Activity** — imports, compatibility checks, environment maintenance, queued launches, and launch results.
- **Settings** — app-wide launch support, runtime, storage, diagnostics, and version information.

Controls, compatibility, storage, saves, and Windows-environment maintenance belong to a specific game and therefore live under Game Detail. The retired root-level Prefixes and Input screens must not be restored as parallel management surfaces.

## Interaction principles

- Show one prominent next action before technical status.
- Describe JIT as **launch support** in primary flows; retain exact JIT terminology in setup and diagnostics.
- Keep errors actionable: say what is blocked, preserve imported data, and expose the recovery action beside the message.
- Treat LiveContainer repair as process-scoped. When a relaunch is required, do not imply that an in-process recheck can apply the repaired picker hook.
- Keep destructive Windows-environment operations behind confirmation and state what is retained.
- Move session identifiers, graphics paths, frame surfaces, and bridge telemetry behind progressive disclosure.
- Let runtime-player controls auto-hide only after the first guest frame. Startup and failure state must remain visible.

## Accessibility and visual behavior

Product cards use semantic system colors and support light and dark appearance. At accessibility Dynamic Type sizes, artwork and copy stack vertically rather than compressing text into narrow columns. Buttons keep system control sizing, icons have text alternatives or are hidden when decorative, and Reduce Motion disables the runtime player's chrome animation.

## Verification

Changes to this experience should preserve:

- unit coverage for every activation-state transition;
- a successful iOS simulator build using the current Xcode beta;
- light, dark, and accessibility-size screenshot checks on a compact iPhone layout;
- the existing import, JIT, runtime, and store test suites;
- physical-device validation as the only proof of a real first rendered game frame.
