# Steam background transfers and local Live Activity

This guide describes the retained Iridium Steam downloader. The frontend app
uses the downloader supplied by `vendor/Madeira`.

The retained implementation separates its native downloader into authenticated
request planning, system-owned encrypted HTTP downloads, and permitted-runtime
verification/assembly. Original integration code remains AGPL-3.0-only. SteamKit
3.4.0's public `DepotChunk.Process` performs decrypt/decompress/Adler verification;
the existing `VerifiedFiles` chunk SHA1, whole-file SHA1, safe paths, independent
repair copies, and final receipt promotion remain mandatory. No new dependency,
source pin, Steam proxy, or Madeira/SwiftSteam code is introduced.

## Execution and transfer bounds

Standalone iOS 18+ queues at most 128 tasks and 128 MiB of expected encrypted
payload per batch. Planning spans files and excludes chunks already verified in
the destination partial or reusable source. Each chunk must declare a nonzero
compressed length no larger than 16 MiB. Unknown lengths fail with a specific
message rather than silently bypassing bounds. The native assembler processes one
chunk at a time on this route; URLSession owns the HTTP connections. Foreground
LiveContainer keeps the existing one-to-eight managed download connections.

The storage preflight reserves an additional 128 MiB for the raw batch, in addition
to the existing assembly requirement and 256 MiB safety margin. The existing
one-attempt, account/job-bound storage override never skips length, hash, path or
write checks. A raw cache is disposable; changing operations discards only that
cache, and never verified partials, receipts, game files or saves.

Transfers are explicitly user initiated in the foreground, nondiscretionary at
submission, Wi-Fi only, and wait for connectivity. iOS may still defer them. No
per-chunk completion callback schedules another chunk. After an entire batch's
events have been persisted, a resident operation may request a short UIKit
background task and use up to ten seconds to verify and submit the next batch.
The native runtime gate is revoked once the next batch has been handed off. If
the time budget expires during processing, cancellation checkpoints a resumable
pause and stops pending HTTP tasks. A cold process, unavailable protected data,
or unavailable runtime does only durable raw-file preservation and finishes the
system completion handler. Reopening and explicitly resuming under the owning
account is then required. No callback performs a cold-process Steam login.

This is an opportunistic background pipeline, not a guarantee of continuous
multi-gigabyte throughput. Apple's wake throttling, resource policy, auth expiry,
network changes, force-quit and user cancellation can interrupt it. Completing a
hash of a large file may exceed a wake budget; it is cancellable and retried on
resume. There are no audio/PiP keepalives, push wakeups or server proxies.

On iOS 26+, an immediate user action may additionally request a
`BGContinuedProcessingTask` with the `.fail` strategy, observed verified-byte
progress, expiration cancellation, and explicit completion. Automatic queue
advancement never creates a new continued-processing request. Rejection uses
the iOS 18 route. This route requires no background GPU or push entitlement.

## Authentication and durable recovery

Only the existing authenticated Steam server directory selects HTTPS, nonproxy,
matching-host servers that allow the authorization app. Native plans contain
short-lived CDN query authorization and are taken once through a private ABI.
They are zero-freed by the existing ABI allocator. Depot keys remain in managed
memory. Plans are not included in UI snapshots, queue files, receipts or logs.
The operating system necessarily retains the submitted HTTP request to transfer
it while the application is suspended.

The request carries only the minimum Steam-issued CDN query token when needed,
with no Authorization header, cookies, account password/session token, pairing
data or depot key. Steam issues the token for the requested app, depot and host
and returns an expiration timestamp; the planner does not reuse an expired token.
No fixed lifetime is assumed. A daemon-deferred request may outlive that timestamp
and must fail/re-authorize during a later permitted runtime. The transport cancels
non-TLS authentication challenges rather than consulting ambient credentials.

A nonsecret, atomic journal stores version, operation UUID, batch UUID, depot/hash
chunk ID, exact expected length, task ID and fixed state/error categories. A task
is persisted before it is resumed. Delegate files are moved before the delegate
returns, with a fresh filesystem length check and first-unlock file protection.
Ready means raw payload retained, not authenticated content verified. The managed
pipeline always decrypts and verifies it before assembly. Corrupt ciphertext is
discarded for a fresh authenticated retry. The batch handoff rejects stale IDs;
the host rejects old task IDs, late completion after cancellation, and mismatched
account/job handoffs. Failed batches rotate servers and refresh authorization
with six bounded attempts; authorization failure does not fall back to unauthenticated
or insecure transport.

After a process restart, unfinished tasks are cancelled and the queue recovers as
paused. Completed raw payloads remain reusable under the same operation identity,
but current manifests and authorization are resolved again before use. Sign-out
stops pending raw transfers and discards their cache. Unreadable journals are
retained and block new transfer submission. Replanning removes generated raw files
outside the new batch, including remnants of a process crash; unexpected entries
or links block this cleanup. Unconfirmed native shutdown blocks
another install. The existing Cloud/file-operation gates remain in force.

## HTTP limitations

Only exact HTTP 200 responses from the planned HTTPS host, port and path can be
retained. Wrong or missing raw lengths cannot be promoted; a missing Content-Length
is accepted only if the final regular file has the exact manifest length.
Observed oversized progress cancels the task. Header and persisted-file bounds
are covered by deterministic fixtures.

Apple follows redirects automatically in a background session and does not let
the application veto them using the ordinary redirect delegate. Rejecting an
unexpected final origin does not prevent a trusted CDN from redirecting a request
earlier. Likewise, callback delivery is asynchronous: planned/retained bounds do
not create a hard limit on transient daemon bytes if a server sends an oversized
body while the app is suspended. These are platform constraints that require
review and device evidence; the implementation must not claim pre-redirect veto
or an exact daemon disk quota. No server-specific transport workaround is assumed.

## Standalone Live Activity and signing layout

`SteamDownloadWidget.appex` is embedded under the app's PlugIns directory with an
app-prefixed bundle ID, the same marketing/build versions, automatic signing and
an empty development team for the maintainer to choose. The app and extension
share only the ActivityAttributes/intent source. There is no App Group or APNs
entitlement, no shared credential container, and `Activity.request` uses
`pushType: nil`. Apple Food Truck explicitly supports Personal Team signing for
its basic app and Widgets targets. Signing and installation of Iridium's layout
still require a separate authorized device validation; SDK typechecking cannot
establish Personal Team provisioning success.

The app starts the activity only in the foreground if local activities are
enabled, updates it only during legitimate runtime, and ends it on pause,
completion, cancellation or failure. The view shows verified bytes, phase and
last-update time, and marks information stale after 30 seconds. It never animates
a simulated transfer or infers remaining time. The authenticated Cancel intent
opens the standalone app and uses its existing queue cancellation path. Old
activities are removed during foreground queue recovery. Widget registration and
Live Activities are unavailable to LiveContainer guest apps, which keep an honest
foreground-only explanation.

## Validation boundaries

`ci/check-steam-queue.py` runs the actual Foundation journal, length/path policy,
queue and account-isolation tests, plus a URLProtocol HTTP fixture through the
actual URLSession download delegate using an ephemeral test-only configuration.
The fixture performs no Steam/network login. It does not simulate the iOS daemon,
suspension, scheduling or wake budget. Managed tests exercise bounded planning,
one-time handoffs, cancellation/stale IDs, runtime permission, storage reservation,
and deterministic AES/ZIP ciphertext through the public SteamKit processing API.
They must also run as NativeAOT with the pinned .NET 10.0.401 SDK before release.
Actual Apple SDK typechecking covers the app, shared intent and widget APIs.

Before claiming full background game download support, separately validate on a
physical device: more than two complete batches, suspension and wake replenishment,
large-file final hashing, budget expiry, force-quit/relaunch, locked protected data,
Wi-Fi loss/recovery, expired CDN auth, user/system cancellation, account switch,
disk-full failure, local activity staleness and cleanup, and Personal Team app plus
extension signing. Record device/OS/game/build and source revision without secrets.

## Primary sources

- [Apple background URLSession downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple background session configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))
- [Apple background strategy selection](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [WWDC25 background execution and continued processing](https://developer.apple.com/videos/play/wwdc2025/227/)
- [Apple local ActivityKit lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple Food Truck Personal Team setup](https://github.com/apple/sample-food-truck)
- [LiveContainer extension limitations](https://github.com/LiveContainer/LiveContainer#limitations)
- [Pinned SteamKit CDN client](https://github.com/SteamRE/SteamKit/blob/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7/SteamKit2/SteamKit2/Steam/CDN/Client.cs)
- [Pinned SteamKit chunk processing](https://github.com/SteamRE/SteamKit/blob/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7/SteamKit2/SteamKit2/Steam/CDN/DepotChunk.cs)
