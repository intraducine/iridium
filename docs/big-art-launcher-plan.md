# Native Big Art launcher

Base: `0402aeb45cb4a8cec6f778d87f3fd5e7576c2572`, branch
`feature/big-art-launcher`. Madeira and PPSSPP remain at their existing pins.

Study Valve's Big Art home screen using REA 6.5.0, its official reference image,
and bounded static inspection of the public Steam UI snapshot. Record observed
behavior separately from iPhone adaptations. No Valve implementation or artwork
is included in Iridium.

1. Preserve the unified library, artwork overrides, imports, settings, launch
   orchestration, and shared gameplay controls. Change only launcher presentation.
2. Give selected artwork most of the screen. Place a compact carousel low on the
   page, with the first featured game wide and subsequent covers portrait. Steam's
   inspected renderer features index zero; it does not widen every focused card.
3. Use one selection model for title, backdrop, border, controller and touch.
   Native touch scrolling never snaps or issues corrective scroll requests.
   Selection tracks overlap with the leading focus area; only explicit navigation
   requests reposition the rail. Tapping a card selects; Play launches.
4. Use measured text/control heights, safe areas, single-line titles and 44-point
   controls. Portrait places details above the rail; landscape places them below.
   Large text retains scrollable overflow. Respect Reduce Motion and contrast.
5. Execute geometry/selection regression tests and required repository checks,
   build the actual app locally, and validate the exact launcher source in a
   simulator harness with synthetic library services. Capture landscape,
   portrait, compact and large-text screenshots. State harness/runtime limits.

Reference: [Valve announcement](https://steamcommunity.com/gid/103582791457287600/announcements/detail/710037059469839721),
[Valve screenshot](https://clan.fastly.steamstatic.com/images/4397053/03ebb301c5968af4cccce2854fbff30f91747e07.png),
[REA](https://github.com/morluto/rea).

Public UI snapshot inspected: SteamTracking/SteamTracking
`5d62cc5ba3f1cebb34053ebc63ad247f21da1802`. This is analysis input, not a
redistributable frontend dependency. The local Steam UI changelist `10971728`
does not contain Big Art identifiers. Dynamic live Big Art behavior on this Mac
has therefore not been verified.

Review correction: invalidate the touch cover size when the actual viewport
height changes, while keeping idle touch geometry stable. Portrait uses the
existing cover for automatic artwork, respects explicit and legacy background
choices, and fills a substantial hero region with a gradual fade into controls.
Landscape framing remains unchanged. Judge composition from native Hades,
Celeste and Hollow Knight captures and inspect transition frames as well as
settled screens. Validate the largest text size, launch callback counts and
controller routing in both orientations using the simulator harness.
