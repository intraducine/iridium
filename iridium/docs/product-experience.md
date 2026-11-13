# Using Iridium

## Install

Choose Stable or Nightly from the [download links](../../README.md#install).
Copy its AltStore source URL and add it under **Sources** in AltStore Classic
or LiveContainer. For manual installation, sign the IPA with a tool that supports
app extensions or import it into LiveContainer.

When updating, back up your saves and install over the existing app or
LiveContainer entry to keep your library and settings.

### Nightly AltStore source

Use this URL when a [Nightly build](https://github.com/intraducine/iridium/releases?q=nightly-)
is available.

```text
https://raw.githubusercontent.com/intraducine/iridium/altstore-nightly/altstore/nightly.json
```

## Add games

Open **Add Game** and choose a source:

- **Files and Folders** imports games and ZIP or 7z archives. Select the full
  folder for Windows games and disc images with separate track files.
- **Import Folder** processes files you place in Iridium’s `Documents/Import`
  folder. If an import fails, the file stays there so you can retry.
- **Stores** opens Steam, GOG, Epic Games, EA, and itch.io. Use your own account
  to download games you own.

See [supported formats and save locations](../../docs/console-engines.md#import-and-storage).
Supply any firmware your games require.

## Play

Select a game and press **Play**. A **JIT** label beside the system name means
you need to [set up JIT](builtin-stikjit-ios27.md). The loading screen shows the
current step, elapsed time, and memory use. To stop, select **Cancel Launch**
when it appears.

Use the in-game menu to pause, change controls or performance settings, and
close the game. Save your progress before closing. The Help page lists input
mappings. See [mouse setup for Windows games](mouse-input.md). To run a required
EXE or MSI installer, use **Game Options → Run Installer**.

## Manage games and saves

Use **Game Options** to change controls, launch settings, or
[artwork](library-artwork.md). **Remove from Library** keeps the files.
**Uninstall** removes a store game’s files. Saves stored inside the game folder
are removed with it, so back those up first. A missing file may offer **Repair**
if the store supports it. Keep older game copies until your saves work in the
new copy.

Use **Settings → Iridium** to change touch haptics and the default game volume.
Per-game volume settings take priority. Restart Iridium after changing Windows
settings that apply when the runtime starts.

If a game fails to start, check its files and JIT setup. If the problem
continues, export a log from Diagnostics and remove private information before
sharing it.
