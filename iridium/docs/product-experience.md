# Using Iridium

## Add and play

Choose **Add Game → Files and Folders** for local games, ZIP/7z archives, and
pairing files. Select complete Windows folders or console files with their tracks.
**Stores** opens Steam, GOG, Epic Games, EA, and itch.io. Sign in to the chosen
store with your own account. Supply your own games and firmware.

`Documents/Import` accepts files and folders in bulk, in standalone Iridium or
LiveContainer. **Import Folder** shows progress, choices, and retry errors. Inputs
leave that folder only after a game record or validated pairing record is saved.
Failed inputs remain there. Managed games use `Documents/Games/<title> - <UUID>`.
Existing managed installs move there without changing game IDs or save paths.
See [storage and recovery](../../docs/console-engines.md#import-and-storage).

Select a cover, then **Play**. Game Options contains title/artwork, controls,
files/saves, launch arguments, and engine settings. Removing a library entry
keeps its files. Deleting game files can also delete saves stored in that folder.

Store games also have **Uninstall** in their options, including missing installs.
Deleting a whole managed game folder in Files clears its install record on
refresh. Partial damage remains available for repair where the store supports it.
A disconnected external drive does not remove its games from the library.

The loading screen shows the current stage, elapsed time, and live app memory
use. It stays until the game is ready or launch fails. A middle dot followed by
**JIT** beside the system name marks games which need JIT, including PSP when its
JIT mode is selected. Menu sound effects are absent from this integration.

For Windows prerequisites, use **Run Installer** with the required EXE or MSI.
Successful groups are remembered. Closing requests cancellation; follow any
restart message before another session.

## Controls

Use touch, a controller, or a keyboard. The player menu provides Resume,
Controls, Performance, Close Game, and logs. See its Help page for key mappings.
Closing can lose unsaved progress. Backgrounding pauses; resume explicitly.

Edit artwork under **Game Options → Rename & Artwork**. Custom images and names
are stored separately from game paths and saves. Missing artwork does not block play.

## Settings

**Settings → Iridium** sets touch haptics and default game volume. Games with a
saved volume keep that value. **Stores** and **Import Folder** open separate sheets.
Getting Started opens the same Stores page. Setup completion is saved separately
from app preferences.

[JIT & Memory](builtin-stikjit-ios27.md) configures shared JIT. Windows sync
mode changes require a full app restart. Display & Memory settings apply to the
next launch. Compatibility and performance vary by game and device.

Back up saves before updates or repairs. Keep old game copies until saves work
in the new copy. Export redacted logs from Diagnostics when reporting a problem.
