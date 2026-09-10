# Mouse input investigation, 2026-09-09

Device evidence: `/tmp/iridium-mouse-probe-device.log` and
`/tmp/iridium-mouse-probe-engine.log`. The captured iPhone test reported one
mouse/profile, installed handlers, an active app, zero motion/button callbacks,
and zero sampled button changes. This does not identify the OS failure itself.

## Current implementation

The Madeira player is presented in its own UIHostingController, which requests
UIKit pointer lock while its control panel and sheets are closed. Requests are
limited to an active app with a connected mouse and AssistiveTouch disabled.
The actual scene pointer-lock state controls delivery of raw GCMouse events.
Revoking capture releases held mouse buttons. Capture requests and granted
state are logged separately; a request is not evidence of success.

The rendering view uses a local tablet trait override to let its pointer
interactions participate on iPhone without replacing UIKit methods or changing
the application's overall interface idiom. This is an experimental compatibility
approach; iOS may still decline capture or deliver no events.

When unlocked, UIKit hover and pointer/touch contacts go directly to the Wine
input queue. Previously these contacts were written to the legacy runtime file,
which Madeira does not consume. The fallback handles one contact at a time,
releases on cancellation/teardown, and clamps coordinates to the drawable.
AssistiveTouch must be enabled by the user in Settings; Iridium never changes
that setting. Its fallback may require click-and-drag for camera movement and
does not promise unrestricted relative motion, right-click, or wheel support.

## Evidence boundaries

Local tests cover contact ownership, down/move/up/cancel, teardown and coordinate
bounds. A successful iOS build does not prove physical mouse input. No physical
device was accessed for this change. Still required: capture grant, mouse motion,
button events, fallback click/drag, menu interaction and app-switch release on
an iPhone running iOS 27.

## Sources reviewed

- Apple pointer lock and UIKit input: https://developer.apple.com/videos/play/wwdc2020/10094/
- Apple trait overrides: https://developer.apple.com/videos/play/wwdc2023/10057/
- Amethyst reference commit: 9212a1894865e7ac0466029e25ddb0d895544c76
- Amethyst iOS 27 failure report: https://github.com/AngelAuraMC/Amethyst-iOS/issues/288

This implementation uses public UIKit APIs; it does not copy Amethyst's private
method replacement or use its unchecked instance-variable writes.
