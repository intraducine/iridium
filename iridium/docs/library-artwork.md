# Artwork

Windows metadata uses the public Steam catalog; SteamGridDB is optional and its
key stays in Keychain. Console matching uses per-platform Libretro catalogs.
Search sends a cleaned title, not executable contents or parent paths.
Ambiguous matches need a choice. Catalog failures do not block launch.

Use **Game Options → Rename & Artwork** to change a match, name, cover,
background, or crop. Local imports are limited to 25 MB and downsampled to
2048 pixels. Overrides are stored by game UUID under
`Application Support/LibraryArtwork`, separate from saves and launch records.
Manual choices take priority over pending automatic results.

Artwork belongs to its rights holders. Custom images stay local; the app links
to the selected source. No commercial game artwork is bundled as sample content.

The retained isolated UI checks run with
`apps/ios/Scripts/check_library_ui.sh` and Xcode/XcodeGen. They do not validate the
complete current app. Use [device testing](manual-validation-runbook.md) for
current touch/controller, accessibility, persistence, and rotation checks.
