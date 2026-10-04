# Steam Cloud saves in isolated game prefixes

Iridium's Cloud integration is opt-in for each Steam account and library game.
It uses the existing SteamKit2 3.4.0 NativeAOT worker and JSON C ABI. Account
credentials, token storage, account settings, depot installs, and download queue
formats are unchanged. Cloud and download operations share one worker gate.

## Supported mappings

Only Steam-provided Windows Auto-Cloud `ufs/savefiles` rules are supported.
`GameInstall` maps to the prepared `drive_c/IridiumGame` copy, never the imported
source. Windows Documents, Saved Games, and AppData roots map only when the
prefix has one unambiguous user profile. Account placeholders are expanded using
the authenticated Steam ID. Rule patterns, recursive scope and platform flags
are retained. Windows root overrides, unsupported roots, encrypted files,
SDK Remote Storage paths and explicit HTTP upload bodies
need a separately verified runtime contract; they do not produce simulated
success. A single unsupported path stops the comparison without transferring
other saves. The feature does not promise Cloud support for all Steam games.

The host prepares the prefix and game copy through `SteamCloudPreparation` and
the existing `MadeiraGamePreparation` helper before receiving saves. It seeds only
a new or empty prefix, never an existing nonempty prefix. The backend refuses
transfers before the game-copy baseline marker exists. Later normal preparation
preserves synchronized saves when the imported source did not change. Existing
source/copy conflicts still require the existing explicit refresh-and-backup
flow; Cloud does not bypass it.

Paths reject absolute names, traversal, streams, malformed components,
case collisions, and symlinks under the trusted sandbox anchor. An ambiguous
profile is unsupported. File/tree sizes, recursion and file counts are bounded.
The opened file length is bounded again before allocation, even if it changed
since the pre-open stat. Local save reads require a writable, seekable file handle so a FIFO cannot
block a read-only open. Read-only or special saves fail safely without changing
permissions. The trusted iOS Documents/Application Support anchors are canonicalized before
use because `/var` is an OS alias. Filesystem operations run off the UI actor.
An app-wide MainActor lease excludes Cloud preparation/transfers and source,
prefix, installer, import, registration, relocation and deletion operations in
both directions. Mutation entry points acquire before scheduling/awaiting work
and release after it finishes. The global scope covers overlapping source paths
across library entries. The launch gate also excludes runtime writes. A Cloud
operation with unconfirmed native shutdown retains ownership until restart;
cancelling its UI never releases files while native writes may remain active.
Queued Steam downloads wait before beginning while this lease is held and resume
when it is released. Cloud preparation and file mutations also refuse to start
while a native download is active or its stopped state is uncertain.

## Consent and comparison

`Game Options → Steam Cloud` compares saves without transferring them. Enable
requires explicit consent to download and upload this game's saves with the
signed-in account. The durable authority is the backend record scoped by Steam
ID, app ID and library UUID. A separate host index remembers which games need a
pre-Play warning while offline; it never authorizes transfers. Sign-out and
account changes discard visible Cloud results. Another account gets its own
consent, baseline and backups while existing local saves remain in place.

Matching SHA-1 and size establish a baseline. A one-sided change from a verified
baseline can sync after consent. First saves, two-sided/no-baseline differences,
and missing local or remote saves require a per-file choice. Missing local saves
are remembered so a fresh save of the same name cannot silently replace Cloud.
Keeping a save missing on the device retains the remote file. No local or Cloud
file is deleted. A changed remote copy invalidates a keep-missing choice.

Choices bind to the compared local and remote hashes and are rejected when stale.
The backend rechecks both sides after making backups. Uploads then recheck the
Cloud listing change number and target hash after opening the batch and again
before commit. The pinned API exposes no expected-hash conditional commit;
these checks and Steam's batch coordination are not an atomic compare-and-swap
promise. The unused batch response change number is not treated as a CAS token.
Avoid concurrent play/sync on another device while making a save choice.

## Launch, exit and cancellation

Before Play, selected games compare and can receive safe one-sided remote
changes. This preflight never uploads local bytes: cancelling a launch must not
send saves. Unresolved changes or offline/failure states offer Choose Saves,
Play with Device Saves, or Cancel. Play with Device Saves waits until native save
writes have stopped, and it makes no claim that Cloud succeeded.

Only the adapter's confirmed terminal callback may schedule automatic upload.
It already waits for Wine and wineserver to stop. A launch failure/no-render exit,
explicit player Close/cancellation, or shutdown timeout does not trigger upload.
Explicit Close is conservatively deferred to manual sync because it can also
cancel prerequisites or a pending game start. A failed/offline/busy exit sync is
shown on the game's Cloud page, with local saves retained for manual retry or
next-launch comparison. Backgrounding cancels active Cloud operations. There is
no app-termination upload, no upload-and-quit, and no Cloud transfer while a game
is still writing saves. Force termination retains the durable journal.

## Backups and recovery

Before the first side effect, each existing device and Cloud copy is backed up
and verified. Backups live under `Documents/Steam Cloud Backups`, separated by
hashed account ID, app ID and library UUID. Each operation folder contains
`backup.json` (identity and mapped path), `device.bin` and/or `cloud.bin`.
They are visible in Files and are not automatically deleted. Each sync needs
space for these retained copies and staging; a storage failure keeps originals.

A flushed pending journal precedes any save write/upload. Downloads are bounded,
verified against Steam metadata and atomically replace the local file. An upload
requires file commit, blocking batch-completion acknowledgement and a fresh
listing confirming the uploaded hash/size. Failure/cancellation leaves an
interrupted record. Recheck Interrupted Sync discards the uncertain baseline
for that path and compares both copies again; it never assumes success or
blindly repeats an upload. A local backup restore keeps the current save as an
undo backup and requires a new choice before any subsequent Cloud replacement.
The previous Cloud copy is also retained in `cloud.bin` for manual recovery.
Offline copies remain accessible through Files; in-app restore requires the
matching signed-in account and a current verified mapping.

The first-party code is original AGPL-3.0-only integration code. Behavioral
research: [Madeira PR130](https://github.com/willfaust/Madeira/pull/130) and its
follow-ups `f369bc0c4a7d7597b3a7e54a5cded87189bc7ebe`,
`f66f93edf8419038f25714c2b227abbbf40bb4c3`, and
`cd700bc798bd14a64f1934b9bf7b36aaea67cfcd`, inspected through
`4e9d45a74294cd820120791c4b3f2b79adf4fc70`. No Madeira Cloud/Dock code or
SwiftSteam transport is copied or linked. Dependency versions/notices and source
collection inputs remain unchanged. Primary protocol references are the pinned
SteamKit generated Cloud messages, [Steam Auto-Cloud documentation](https://partner.steamgames.com/doc/features/cloud),
and [ICloudService documentation](https://partner.steamgames.com/doc/webapi/icloudservice).

## Validation and limits

Run the existing managed and NativeAOT Steam test program. `CloudTests` uses only
synthetic save bytes and an in-memory transport. It checks consent, stale choices,
missing saves, account/app isolation, backup failure, rollback, interruption,
version races, first-preparation refusal, path/HTTP bounds and compressed saves.
New typed Cloud protobuf routes, including nested upload blocks/headers, run in
both managed and NativeAOT tests. The exported C ABI checker rejects Cloud
requests while signed out. `python3 ci/check-steam-cloud.py` exercises the actual
Foundation preparation helper, later save preservation and Swift JSON contracts.
The host fixtures also run actual mutation entry-point bodies with mocked file
effects, testing Cloud-first and mutation-first exclusion and lease lifetime.
`ci/check-steam-ui.py` typechecks the Steam model and Downloads screen with host
declarations; it does not compile the Cloud views/coordinator. A full unsigned
Xcode app build and separate Apple SDK checks validate the actual Cloud UI and
runtime integration.

Managed/Linux NativeAOT tests do not establish iOS framework compatibility,
physical-device UI behavior, real authenticated Cloud permissions/storage hosts,
or game compatibility. No real account login or Cloud transmission is part of
these tests. Unsupported service hosts fail closed; currently accepted HTTPS
hosts are Valve Cloud domains and the SteamCloud Google storage family shown in
Valve's official example. Redirects, HTTP, URL userinfo/ports/local addresses,
credential/host override headers and explicit upload bodies are refused. Other
storage providers require reviewed evidence and tests before support.
