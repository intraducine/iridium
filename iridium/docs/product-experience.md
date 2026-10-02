# Using Iridium

## Add a game

Choose **Add Game (+)** in the library, then select the folder containing the
Windows game and its `.exe` file. Confirm the game name and executable.
If several executables are found, choose the one that starts the game.
Custom and unreleased games can use their own names and images.

Artwork is optional. Edit the name, catalog match, cover, or background in
**Game Options → Rename & Artwork**. Artwork matching is independent of game
compatibility.

## Choose and play

Use **All Games** or **Favorites** to browse. Search finds games in your library.
Select a cover and choose **Play**. When setup needs attention, follow the action
shown beside the launch message, such as locating a game file or enabling JIT.

JIT allows the runtime to translate Windows game code. Launch Support in Settings
contains setup options. External StikDebug setup uses LiveContainer2. A prompt to
restart Iridium requires closing and reopening the app before continuing.
Compatibility and performance vary by game, runtime, and device.

## Game Options

- **Rename & Artwork:** edit the game's name and images.
- **Controls:** view connected devices and input guidance.
- **Files & Saves:** view the game folder and available save information.
- **Run Installer:** choose a Windows `.exe` or `.msi` installer. It runs in this
  game's Windows environment before the game starts. Complete any setup prompts.
  The player shows the Windows installer and its current step. Tap its buttons
  directly or use a keyboard and mouse. The RAM bar measures Iridium's memory
  use and space available to the app; it is not a loading percentage.
- **Advanced:** launch arguments and runtime settings.
- **Remove from Library:** remove the entry while keeping game files and saves.

Use Game Options to add a game to Favorites. Save locations vary by game; check
the game's documentation before backing up or moving save files.

Use Run Installer for a missing game prerequisite, such as PhysX. Choose an
installer that contains its required files. Successful setup is recorded so it
does not run again on each Play. Choosing an installer again requests a new run.
The original installer and existing game saves are kept. Restart Iridium before
another runtime session if requested.

## During play

Open the menu at the right edge for **Resume**, **Controls**, **Performance**, or
**Close Game**. Tap outside the menu to dismiss it. Closing a game asks for
confirmation because unsaved progress may be lost. **View Log** opens the full
session log when troubleshooting.

## Settings and support

Settings contains launch support, runtime information, artwork settings, storage,
and diagnostics. Storage shows the device's capacity and available space.
Use diagnostics to export logs when reporting an import or launch problem.

## Interface writing

Describe the current action, result, or next step. Keep labels consistent with
the screen they open. Explain compatibility limits where they affect a choice,
and state data-loss risks before destructive actions. Put implementation history
in dated engineering records and release notes.

References: [Apple writing guidance](https://developer.apple.com/design/human-interface-guidelines/writing)
and [GOV.UK interface writing](https://www.gov.uk/service-manual/design/writing-for-user-interfaces).
