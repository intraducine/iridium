# Artwork library

The library now reads its shelf from registered GameRecords. No game titles, catalog IDs, or covers are bundled into the production UI. Existing import and launch operations still own game files and saves.

## Import and matching

- The public Steam store catalog is the default metadata source. It does not check Steam ownership or require a login. SteamGridDB is an optional alternate source; its key is stored in Keychain.
- Only a cleaned title is sent for search. Parent folders and executable contents are not uploaded.
- Automatic matching requires one exact normalized catalog title and a matching executable basename. A folder name alone is insufficient. Generic executables and ambiguous names remain unmatched.
- This version does not parse PE version resources or maintain an executable-signature database. Use Game Options > Edit Name and Artwork > Find Matches for those cases.
- Games absent from either catalog remain playable with a local title and fallback artwork. The importer also checks explicit root artwork files (cover.jpg/png, folder.jpg, icon.png, game.ico), without scanning textures or saves.
- Download failures do not gate launch. Catalog lookup is best-effort; Valve's public store endpoints are not a versioned, guaranteed third-party service.

## User choices

Names, favorites, catalog matches, cover/background images, and crop positions live in Application Support/LibraryArtwork, keyed by the existing game UUID. Library display overrides do not mutate executable paths, prefixes, compatibility settings, or saves.

Photos and Files imports are decoded, downsampled to 2048 pixels, and stored locally as JPEG. The limit is 25 MB per source image. A vertical crop slider previews the selected image. Explicit custom images and explicit removal of an image take priority over catalog images. Change match, Remove Match, Use Original Name, and Use Matched Artwork are separate actions. Removing a match disables automatic rematching, including a lookup already in flight. Atomic metadata writes protect existing choices; malformed saved metadata is preserved rather than replaced. Superseded files in the private artwork cache are removed only when no entry references them.

## Input and layout

The landscape shelf uses selected-game artwork as a backdrop with native Apple controls. Touch users can swipe, select a game, play, search, and open game options. Portrait and accessibility text sizes use a vertical layout. Focus does not require hover. Reduced Motion disables the selection animation.

Controller reads for the shelf do not replace runtime input handlers: directional input browses, A plays, X opens details, Y opens search, and shoulder buttons change tabs. Native forms use GCEventViewController's UIKit event routing. Menu input is suspended during gameplay; hidden library views and open editors do not receive Play actions. Physical controller navigation, especially native forms, still needs testing on the phone. This change does not establish a fix for the earlier iPhone mouse-event delivery problem.

## Checks

Run `apps/ios/Scripts/check_library_ui.sh` with Xcode 27 and XcodeGen installed. It builds an isolated simulator preview from the production shelf/editor/store files, not a duplicate implementation. Set IRIDIUM_LIBRARY_SIMULATOR to choose an available simulator. Tests cover touch Play/search/rename/relaunch, metadata preservation, invalid images, cache reload, match removal during a request, and anonymous catalog responses. Test fixture names exist only in LibrarySupportTests and are not included in the app target.

CatalogSmoke.swift is an optional simulator executable for a live query supplied as its argument. It tests matching, downloading both image types, decoding, and reopening the cache in an isolated temporary directory. A live run with Hollow Knight passed without credentials. No game launch is part of that check.

Device builds use Xcode-beta and the Madeira scheme. No phone was accessed or installed during this work. Simulator UI tests do not prove physical input or game runtime behavior.

## Artwork sources

- [Steam public catalog response](https://store.steampowered.com/api/appdetails?appids=367520): source of default image URLs. Catalog IDs in production come from search responses.
- [SteamGridDB API client documentation](https://github.com/SteamGridDB/node-steamgriddb): optional authenticated artwork service.
- [Apple controller event routing](https://developer.apple.com/documentation/gamecontroller/gceventviewcontroller/controlleruserinteractionenabled): native menu input routing.

Artwork remains owned by its respective rights holders. No game art from the concept is bundled with the production app. The editor links to the selected artwork source. Custom images stay local. Example screenshots use an explicitly assigned local test image; they do not demonstrate automatic recognition of the arbitrary fixture titles.

## Current verification limit

The final signed device build and runtime package checks passed. The direct simulator storage checker and live catalog checker passed. Earlier touch UI tests passed, but the last automated UI reruns stalled during startup; the complete final native controller host has not received device sign-off. See `design-qa.md`. The debugger warnings alone are not a confirmed cause of those stalls.
