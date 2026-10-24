# Native Steam module

Retained SteamKit2/NativeAOT module for the earlier app. The current frontend
uses Madeira's Steam implementation. This module's C ABI covers authentication,
owned content, verified depot downloads, and opt-in Windows Auto-Cloud saves.
Dependency pins and licenses are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Build and test

Use .NET SDK 10.0.401. From the repository root, run
`python3 ci/prepare-steamkit.py`, then from this directory:

```sh
dotnet run --project Iridium.Steam.Tests -c Release
dotnet publish Iridium.Steam.Tests -c Release -r osx-arm64 \
  -p:PublishAot=true -o /tmp/iridium-steam-tests
/tmp/iridium-steam-tests/Iridium.Steam.Tests
```

`--network` adds public metadata and QR challenge/cancel checks without login.
Use `win-x64` and `.exe` on Windows. Keep serializer/protobuf/generic roots and
run NativeAOT tests when changing protocol routes.

From the root, `python3 ci/build-steam-framework.py` builds Apple slices.
`ci/check-steam-native.py` checks an exported host library;
`ci/check-steam-ios.py`, `ci/check-steam-queue.py`, and `ci/check-steam-cloud.py`
cover the retained simulator/Foundation paths. Tests do not prove real-account
or device download/Cloud behavior.

## Storage and security

- Credentials go directly to Steam over TLS. Saved tokens use device-only Keychain;
  credentials and CDN authorization stay out of queue files and diagnostics.
- The account-scoped queue is atomic. Jobs recover paused after process death.
  Signed-out accounts cannot resume another account's work.
- Validate paths, sizes, chunks, and final hashes before committing receipts.
  Updates/repairs use separate copies and preserve old installations and saves.
- Storage preflight keeps a 256 MiB margin. Download Anyway bypasses only the
  estimate for one attempt; hash/path checks and actual write failures remain enforced.
- Standalone background batches are Wi-Fi only, bounded to 128 tasks/128 MiB
  and 16 MiB per chunk. Runtime performs authentication and verification.
  iOS scheduling, expiry, redirects, and transient daemon disk use remain limits.
  Force-quit requires explicit resume; LiveContainer pauses in the background.
- Protected branches, Workshop, Families discovery, automatic game-local save
  migration, and desktop Steamworks/DRM services are not implemented.

## Cloud

Only supported Windows Auto-Cloud mappings can sync. Consent is scoped by account,
app, and library UUID. First saves/conflicts need a choice bound to current hashes.
Backups precede writes under `Documents/Steam Cloud Backups`; originals are never
silently deleted. Interrupted operations require comparison again.

Play preflight never uploads. Automatic upload requires a confirmed runtime exit;
failed launch, explicit cancellation, or uncertain shutdown defers to manual sync.
Cloud and game/file mutations exclude each other. Stale remote checks do not
provide atomic compare-and-swap; avoid concurrent play/sync elsewhere.

Behavioral research used Madeira PR130 and follow-ups
`f369bc0c4a7d7597b3a7e54a5cded87189bc7ebe`,
`f66f93edf8419038f25714c2b227abbbf40bb4c3`, and
`cd700bc798bd14a64f1934b9bf7b36aaea67cfcd`, inspected through
`4e9d45a74294cd820120791c4b3f2b79adf4fc70`. No Cloud/Dock source or SwiftSteam
transport was copied. Protocol references are pinned SteamKit messages and
[Steam Auto-Cloud](https://partner.steamgames.com/doc/features/cloud).

## Host capacity callback

Register `iridium_steam_set_capacity_provider(void *)` before initialization.
The callback is `int64_t capacity(const char *destination_utf8, int32_t *source)`:
1 means important-usage capacity, 2 raw volume capacity, and 0/-1 unknown.
It runs synchronously on the download worker, queries the actual destination,
and must not throw or access main-actor state. Registration after initialization
fails. An absent/invalid provider reports unknown capacity.
