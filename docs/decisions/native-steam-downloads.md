# Native Steam authentication and downloads

## Decision

Use PR #40's on-device SteamKit2 module behind a small C ABI, compiled with
NativeAOT into an embedded iOS framework. SwiftUI owns the interface and device-only
Keychain persistence. The module owns Steam authentication, account connection,
metadata, authorization, and verified content transfer. No Steam.exe, companion PC,
hosted account proxy, developer API key, or anonymous ownership fallback is used.
The old simulated Steam services are not the native download backend.

Credentials go directly to Steam over TLS/WebSocket. Password, QR and Steam Guard
flows are supported. Refresh tokens cross a separate one-time ABI call to a
non-synchronizing Keychain item. UI snapshots and queue documents never contain
passwords, Guard codes, refresh tokens, or CDN credentials. Sign-out clears the
saved session without deleting installations or saves.

## Native interface and durable queue

Downloads is a native tab beside Library. Queue, Steam, and Installed sections use
the same controller-aware controls, page background, glass buttons, and accessibility
conventions as the existing library and settings. Add Game also routes to this tab.
Download options include unprotected branches, language, Windows 32/64-bit depots,
authorized DLC selection, and one to eight chunk connections. File availability is
not a claim that Iridium's runtime supports a selected game's architecture.

Swift persists the account-scoped queue atomically in Application Support/SteamDownloads.
One operation runs at a time; additional jobs queue without replacing it. Pause,
resume, retry, cancel, priority, and completed history are independent of the view
lifetime. Completed downloads remain available for executable selection and library
registration. Removing an entry removes only its history, not its files.

A UUID is saved before native submission and echoed in native snapshots. Late or
unreadable responses cannot be attached to another job. Journal revisions reject
out-of-order checkpoints. A malformed or oversized journal is retained rather than
overwritten. Running jobs recover as paused after process death; only jobs belonging
to the signed-in account may resume. Persistence failure stops the queue.

Downloads pause on backgrounding and require explicit resume. iOS does not grant an
unlimited background lifetime to this Steam session. Cancellation waits for existing
bounded SteamKit requests and prevents further chunk writes after it is observed.
The UI does not confuse verified/reused bytes with newly transferred payload bytes.

## Depot selection and installation safety

Steam supplies app metadata, depot keys, manifest request codes and CDN authorization.
The selected app branch must exist; protected branches fail explicitly. An unchanged
depot may use its public manifest while the installed receipt still records the
actual selected branch/build. Shared depot references are bounded and cycle-checked.
DLC from base-app and separate-app metadata is selected explicitly; inaccessible
optional content is skipped, while denied explicitly selected DLC reports failure.
Authorization considers the DLC/shared owner and base game, and scopes CDN tokens
to app, depot and host. No local list or app ID grants ownership.

Use HTTPS-capable Steam caches, including caches reporting optional HTTPS, strictly
over TLS. Retries rotate available servers with bounded backoff, including retries
when only one server is available. There is no insecure HTTP downgrade.

Default installs retain PR #40's Application Support/SteamGames/app-id/build-id
layout for partial compatibility. Different content selections use a deterministic
variant directory; connection count does not change resume identity. Receipts store
build and manifest IDs as decimal strings, avoiding unsigned 64-bit precision loss.

All manifest paths, link flags, chunk offsets and lengths are validated before
payload writes. Case-only and file/directory collisions fail safely; exact-path
depot overlays use a deterministic last-selected-depot rule. Chunks and completed
files are SHA-1 checked against Steam's manifests. This verifies integrity against
the manifest, not a separate publisher signature. A complete receipt is committed
only after every selected file passes verification.

Resume checks saved chunks rather than trusting UI progress or sparse file lengths.
The storage check credits only verified partial chunks. Updates and repairs can
reuse matching chunks from a previous installation without downloading them again.
They produce an isolated operation directory, never edit a committed installation,
never hard-link writable game files, and never delete the older version. New repairs use `app-id/installs/operation-uuid` outside the original build folder.
Existing nested `checks` partials remain resumable. Explicit deletion removes only
an installation's `content`, `partial`, and receipt, preserving nested repairs and
variants from older versions. No automatic move or save migration is performed.
A cancelled
or failed operation does not produce a successful receipt.

Registering a repaired/updated app preserves its game identity, prefix, save mapping,
custom title, launch arguments, renderer, controller and touch settings. Two distinct
Steam app IDs with identical display names remain separate. Library registration is
blocked while a game is running. Existing game-local saves are retained in the older
folder, but are not automatically migrated into another build's folder. Prefix and
mapped save locations remain unchanged.

## WinNative comparison and explicit boundaries

Reference: WinNative-Emu/WinNative at
`c9fbbb342f2689c852046804f4f5c9afa45b5dcb`, particularly
`app/src/main/feature/stores/steam/service/SteamServiceDepot.kt`,
`SteamServiceDownloadQueue.kt`, and the `wn-steam-client` Rust downloader.
The existing SteamKit implementation is extended rather than replacing it with
WinNative's Android/JNI or Wine client-integration layer. No WinNative source is
vendored into Iridium by this integration.

The implementation covers the native download-manager features described above,
not all WinNative Steam services. Full parity is **not** established. Known gaps:

- Steam Families/shared-library entitlement enumeration and advanced package-based,
  regional/low-violence and positional/grouped DLC rules. These must not be claimed
  complete merely because basic DLC and shared depots work.
- Game-specific superseded-depot rules, Workshop downloads, external install targets,
  automatic old-version cleanup, and automatic game-local save migration.
- Steam Cloud, friends/chat, achievements, overlays, multiplayer tickets and
  launch-time Steamworks/DRM IPC. A download session is not a desktop Steam client
  and does not replace these game requirements.
- Unlimited background transfers are not promised. Downloads use the app's managed
  storage and pause when iOS backgrounds it.

WinNative's inspected branch selector also excludes password-protected branches.
Supporting public/unprotected beta branches here is not support for encrypted beta
password flows. Games requiring desktop Steam, anti-cheat, or unsupported runtime
features can still fail to launch after a fully successful download.

## Validation and rollback

Run `python3 ci/check-steam-queue.py` for the real Foundation queue/persistence tests,
the managed and NativeAOT executables in `iridium/packages/steam`, and the
`SteamDownloadRegistrationTests` core tests. `ci/check-steam-ui.py` type-checks the
real Steam model, views, shared controls and chrome with an iOS SDK, isolating only
the unrelated runtime/artwork host declarations. A full application build remains
necessary to validate the complete host integration.

Physical-device validation must cover password/Guard/QR login, real authorized game
and DLC downloads, branch/language selection, sign-out/account switching, network
loss, low storage, pause/resume, backgrounding, force-quit recovery, repair/update,
controller navigation, VoiceOver, large text, standalone and LiveContainer hosting.
Test game launch separately from authentication/download success. A compiler or
synthetic fixture success is not evidence of real Steam or device compatibility.

No library schema migration is required. Removing the native integration returns to
manual import. Preserve SteamGames directories and existing Keychain/queue data until
the user deliberately removes them. Do not delete previous game versions or saves
as an error-recovery strategy. Keep Actions compilation manual.
