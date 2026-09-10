# Library redesign review

final result: blocked

The source implementation and signed iPhone build are complete. Final visual and input sign-off is not complete.

## Reference and evidence

Reference: the first generated Artwork Shelf concept, followed by the user's requirements for native Apple controls, arbitrary imported games, touch access, and reversible/custom artwork.

The reference and the native custom-artwork screenshot were viewed together. Both use a landscape phone viewport, but their game titles and images differ intentionally: the simulator uses arbitrary fixture titles with an explicitly assigned image. This is not a pixel-identical comparison or proof of automatic recognition of those fixture names.

- `docs/library-ui/custom-artwork-landscape.png`: actual native shelf with a custom image. No such image is bundled into the production app.
- `docs/library-ui/custom-name-portrait.png`: actual portrait UI after changing a display name.
- Earlier XCTest run `Test-LibraryPreview-2026.09.09_09-40-48--0400.xcresult`: touch Play, search, editing, and persistence passed in the isolated production-view preview.
- Live CatalogSmoke: public catalog search, matching, cover/background download, decoding, and offline cache reopening passed without credentials.
- Final LibraryStateCheck: custom images, cache reload, match removal, name restoration, malformed-image rejection, query path cleanup, and corrupt-metadata preservation passed.
- Final Xcode-beta device build and runtime packaging/signature checks passed. No physical device was accessed.

## Review and fixes

- Removed the always-visible search field from the resting landscape screen so it does not displace the shelf.
- Used native Apple type, SF Symbols, and system glass controls, as explicitly requested. These take precedence over the generic website defaults in the design rules.
- Retained the selected artwork backdrop and horizontal shelf. No generated game covers or fixed game list are shipped.
- Increased wrapping space for long cover captions. Accessibility text sizes use vertically arranged actions and a scrollable layout.
- Kept content visible by default. Selection motion respects Reduce Motion; there are no entrance reveals, decorative looping motion, custom glow layers, or fake desktop chrome.
- Checked focus outline clearance, text margins, contrast over the sample image, button alignment, and touch access in the available captures. The source image crops are user-adjustable; the UI does not paint missing game art.
- Keyboard focus now clears on Play, game selection, search submission, and returning from empty search results.
- Automatic artwork failures use a non-blocking note rather than interrupting Play.
- Restored-name assertions were added to the touch test. Its starting state no longer assumes the previous run left the original display name.

## Remaining sign-off

P1: The final automated UI rerun stalls during test startup on multiple simulators, including with debugger attachment disabled and an alternate test driver. Debugger-version warnings appear in logs, but they also appeared in earlier passing runs and are not proven to be the root cause. Do not count these unfinished runs as passes.

P1: Verify the final controller event host, native forms, and player presentation on the iPhone. Library controller code is implemented, but physical behavior is unverified. The pre-existing iPhone mouse delivery issue is not resolved or claimed fixed by this change.

P2: Capture and compare the complete final app, including native tabs, with the selected concept after simulator/device access is reliable. The isolated preview is not proof of every full-app screen. The final all-points visual review remains open for these unavailable states.

## Concept layout follow-up (September 9)

Restored the selected reference's large leading title, Play below the title,
wide three-item landscape shelf, and edge-to-edge dynamic backdrop. Landscape
app navigation now uses a native segmented control above the content. Portrait
retains native tabs. Removed the library-count subtitle and redundant cover
captions when artwork exists. Existing selection, search, editor and runtime
callbacks remain connected.

Reviewed the reference and actual portrait/landscape simulator captures. Fixed
shelf clipping, oversized secondary controls and duplicate safe-area margins.
Checked text contrast, edge clearance, aligned shelf items, visible-by-default
content, reduced-motion handling and dynamic artwork. No new fonts, icons,
artwork dependencies or decorative animation were introduced. Native system
fonts, symbols and glass follow the explicit Apple-style requirement.

The preview and device builds pass. The screenshot uses previously saved test
artwork; it is not a claim that those fixture titles matched that image.
Full-app navigation and physical controller interaction remain unverified.
The earlier blocked overall QA status remains until those checks pass.

## Whole-screen concept rebuild

The production shelf and simulator now share the brand/header navigation,
leading title and single Play action, three wide cover positions, and bottom
Play/Details/Search/Import/options bar. Collections currently exposes All Games
and Favorites. Settings opens the real app settings; the isolated preview opens
artwork settings. The preview's three known titles are enabled only by
--concept-preview; normal test fixtures and production libraries remain dynamic.

Compared actual landscape and portrait captures against the supplied concept.
Fixed narrow navigation wrapping, cover-title cropping, bottom-bar clipping,
and nav centering. Downloaded covers fit intact; user crops remain supported.
Steam library assets are attempted first, with header/screenshot/background
fallbacks. The live catalog/download/decode/offline-cache check passed.

Checked the supplied design rules across typography, spacing, contrast, clipping,
background continuity, image provenance, default visibility, motion and native
materials. No decorative asset placeholders or hardcoded production game IDs.
The source concept's invented artwork is not reproduced: actual catalog images
vary. Remaining limitation: full touch/controller interaction QA is not passed.
Overall final result remains blocked for that interaction verification, not a
claim of pixel-identical completion. No phone installation was performed.

## Portrait and neutral controller hints

Portrait now uses a compact All Games/Favorites segmented control and a four-action
bottom bar. Removed the duplicate root tab bar on the library; Activity remains
reachable from the settings sheet. Added four preview-only entries (Celeste,
Stardew Valley, Hades, Portal 2), with seven cached catalog matches verified.
Controller hints use a four-position neutral face-button silhouette, not brand
letters. Hints follow new controller presses, clear on touch, and clear on
disconnect. The preview now polls input as the real app does.

Portrait was captured and inspected. Fixed action-label alignment. Simulator and
device compilation passed. Physical input-mode switching remains unverified.

## Secondary-screen continuity

Settings (including launch/runtime/storage/diagnostics), Activity, game details,
per-game configuration and artwork editors now use a shared selected-game
backdrop and dark translucent section surfaces. Native navigation, lists, fields,
sliders and buttons remain. Removed redundant colored icon tiles. Backdrop falls
back to solid black with Reduce Transparency. Portrait game artwork also carries
into game details.

Added shelf arrow-key navigation, Command-F search, Escape on sheet Done actions,
and controller back handling. Corrected preview modal input ownership so the
library cannot react beneath settings. Native pointer controls remain in place;
this does not claim to solve the earlier physical iPhone mouse-event issue.

Actual artwork-editor captures were inspected. Fixed opaque list rows and
retained gutters/contrast. Final preview and device builds passed; diff whitespace
check passed. Full app simulator build is blocked by its missing native simulator
Wine server. Automated UI test again stalled at startup and was stopped. Full
input and all-screen visual signoff remains blocked; no phone install performed.

## Shelf alignment, titles, search and action-bar spacing

Game titles now use one line with tail truncation. The selected ID drives a
leading-edge scroll target without scroll feedback changing selection. Added
trailing scroll space so the final game can align left; prior tiles clip at the
viewport edge. Captured the last demo game (Portal 2) and corrected an initial
alignment miss. This is a finite library, not duplicated fake games.

Search now uses the native glass panel. The landscape action bar sizes to its
contents, with a scroll fallback only when needed, instead of a wide empty
scroll area. Reduced landscape poster height so the bar remains visible.
Preview and device builds and diff checks passed. Physical input testing and
full automated UI verification remain pending as noted above.
