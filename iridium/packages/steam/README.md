# Steam on device

This module implements direct Steam client sign-in, Steam Guard/QR authentication,
authenticated library retrieval, and resumable Windows depot downloads. The iOS
shell exposes a native **Downloads** tab, also reachable through **Add Game → Download from Steam**. No PC or API key is used.

## Build and test

Use .NET SDK **10.0.401**. First run `python3 ci/prepare-steamkit.py` from
the repository root to fetch the pinned source and apply the iOS compatibility
patch. Then, from this directory:

```sh
dotnet run --project Iridium.Steam.Tests -c Release
# Optional live test: anonymous metadata and QR challenge/cancel, no account login.
dotnet run --project Iridium.Steam.Tests -c Release -- --network
```

Also publish and run the test executable with NativeAOT. Merely running the managed
tests cannot establish that the serializers work without JIT:

```sh
dotnet publish Iridium.Steam.Tests -c Release -r osx-arm64 -p:PublishAot=true -o /tmp/iridium-steam-tests
/tmp/iridium-steam-tests/Iridium.Steam.Tests --network
```

Use `win-x64` and the `.exe` suffix on Windows. The source-generation JSON contracts,
protobuf reflection roots, and concrete generic roots are required by the C ABI.
Do not remove roots or suppress new AOT warnings without running native tests.
The pinned SteamKit/protobuf packages still emit AOT analysis warnings; these are
not a claim of universal NativeAOT support. The exercised protocol routes must run.

To test the actual exported interface, publish `Iridium.Steam` with
`-p:PublishAot=true -p:NativeLib=Shared` for the host and run
`python3 ci/check-steam-native.py /path/to/Iridium.Steam.dylib --network` from the
monorepo root (use the published `.dll` on Windows). This checks allocation/free,
invalid commands, session isolation, and a live QR challenge followed by cancellation.

On a Mac with Xcode, build the embedded framework from the monorepo root:

```sh
python3 ci/build-steam-framework.py
xcodegen generate --spec iridium/apps/ios/stikjit.yml
```

This creates device and Apple Silicon simulator slices. The manual IPA workflow
and local IPA script build the device slice before generating Xcode projects.
The manual workflow also runs `python3 ci/check-steam-ios.py` on an iOS Simulator:
client construction, offline verification, public metadata, and a real QR
challenge/cancel. This requires an installed simulator runtime and network access,
but no personal account. It does not test account ownership, authenticated
downloads, or physical-device game compatibility.
The rest of Iridium's runtime prerequisites still apply. Tests and framework
creation do not sign, publish, or establish device compatibility.

## Behavior and boundaries

SteamKit's upstream process-start lookup is unsupported on iOS. The pinned local
patch uses a client timestamp for job IDs on iOS/tvOS. Other platforms retain
upstream behavior. Failures report a fixed operation/category code without
including exception messages, passwords, tokens, or local paths.

- Passwords are held only during authentication. Saved sessions go to an iOS
  Keychain item with `WhenUnlockedThisDeviceOnly`; sign-out deletes the item.
- Only one account operation/download runs at a time. Downloads use one to eight
  concurrent chunks (four by default), pooled buffers, bounded retries, and manifest/file hashes.
  Steam cache and CDN hosts are used over TLS only, including hosts that report
  HTTPS as optional; there is no plain-HTTP, proxy, simulated account, or download
  fallback.
- Storage is measured on the destination volume after manifest and partial-file
  verification. iOS uses important-usage capacity (including space the OS can reclaim)
  and falls back to raw volume availability only when that API cannot supply a value.
  Unknown capacity is a separate warning, never treated as zero or unlimited space.
  The estimate retains a 256 MiB margin and the full separate copy needed by repairs.
- A typed storage-preflight failure offers **Download Anyway** with a risk warning.
  It applies to one immediate attempt for that queue job/account; ordinary retry,
  pause/resume, backgrounding and relaunch check storage again. Consent is not saved.
  Hash, path, sparse-partial and actual disk-full/write failures cannot be bypassed.
  Exported runtime logs include only storage counts, source category, override choice,
  and fixed failure codes, without game names, account identifiers or local paths.
- Standalone iOS 18+ downloads use background URLSession for bounded encrypted HTTP
  batches on Wi-Fi. App runtime still performs authorization, decrypt/decompress,
  chunk/file verification and assembly. Resident operations can attempt bounded
  processing and replenishment during a legitimate completion wake; scheduling,
  suspension, budget expiration and force-quit can require reopening and explicit
  resume. LiveContainer retains foreground downloads and background pause.
  See [the background download decision](../../../docs/decisions/steam-background-downloads.md)
  for bounds, recovery, redirect constraints and evidence requirements.
- Installs live in Application Support, excluded from device backups. Each build
  has a separate directory. Existing imported games and their saves stay in place.
- The initial selection is the public Windows 64-bit/neutral English build.
  Unprotected branch, language,
  32/64-bit depot and DLC selection are available in Download Options. Password-protected
  branches, automatic update scheduling and desktop Steam IPC are not implemented.
  Opt-in Cloud saves support verified Windows Auto-Cloud paths only; see
  [the Cloud save decision](../../../docs/decisions/steam-cloud-saves.md).
  Case-only and file/directory collisions fail safely; see the architecture decision
  for exact-path overlay rules and the remaining specialized entitlement gaps.
- Download authorization does not make a game compatible with Wine/FEX. Steam DRM,
  third-party launchers, anti-cheat, and device/JIT limitations can prevent play.

## Device acceptance

Before calling a build ready, test credentials plus each available Guard method,
QR refresh/cancel, token restore, expired-token handling, sign-out, large libraries,
low storage, interrupted network, background/termination/resume, executable
selection, registration, and Play on the target iPad/iPhone. Confirm rendering,
controls, audio, saves, and shutdown for each tested game. Check VoiceOver, large
text, orientation, keyboard navigation, and controller dismissal separately.

See the architecture decision and third-party notices for storage migration and
source/relink requirements. The source collector retains the dependencies. The
[2026-10-03 baseline run](https://github.com/intraducine/iridium/actions/runs/37096956724)
at `25e5763ee1c56b731f9df235e7bbea4f9f0cafba` passed iOS framework/application
compilation, native/simulator checks, source collection, and final binary/package
checks. It still uses app version 0.1.1 and does not establish real-account login,
owned-game downloads, or physical-device compatibility. A 0.2.0 build and its
matching source, bundle metadata, checksums, and recipient signing still need
release verification.


## Native Downloads tab

The Swift front end now maintains an account-scoped, atomic persistent queue, with
explicit pause/resume, retry/cancel, priority and completed-install history. Jobs
carry an operation UUID through the native ABI; callbacks cannot cross jobs.
`Command.options` selects branch, language, Windows architecture, DLC and bounded
chunk concurrency. `Command.reuseDirectory` enables verified-chunk reuse only from
a previous managed installation of the same app. Repairs and redownloads do not
modify committed game folders. Unsigned Steam build/manifest IDs remain strings.

Run `python3 ci/check-steam-queue.py` from the repository root for the Foundation-only
queue tests. The managed and NativeAOT test programs also run `DownloadFeatureTests`.
Core `SteamDownloadRegistrationTests` check identity and custom-setting preservation.
See `docs/decisions/native-steam-downloads.md` for storage rules, device validation,
rollback, and explicit WinNative parity boundaries. No full-parity claim is made.


### Host capacity callback ABI

Before initialization the iOS host must register a process-lifetime, non-capturing
C callback with `int iridium_steam_set_capacity_provider(void *callback)`.
The callback is `int64_t capacity(const char *destination_utf8, int32_t *source)`:
source 1 is important-usage capacity, 2 is raw volume availability, and 0 with -1
bytes means unknown. A negative count or unknown source is rejected as unknown.
The pointer is called synchronously on the native download worker and must not
throw or access main-actor state. It must query the supplied destination afresh.
Registration returns 0 after initialization, preventing a provider from changing
under an active operation. An iOS framework without this symbol is rejected by
the updated host; the original five entry points and existing JSON queues remain
compatible. A host that omits registration on iOS gets an unknown-capacity warning,
not a silently substituted raw-block estimate. Desktop test hosts may use DriveInfo.

## Steam Cloud

Game Options → Steam Cloud compares verified Windows Auto-Cloud saves. Enable
requires per-game, per-account consent; first saves and conflicts require a side
choice. Backups precede replacements, and interrupted transfers require recheck.
Play preflight never uploads. Automatic uploads require a confirmed game/runtime
exit; failed/offline/busy sync is recoverable from the Cloud page. No delete API
is called. Other paths and games report unsupported mapping rather than success.

Run the existing managed/NativeAOT test executable for deterministic Cloud and
protobuf fixtures, and `python3 ci/check-steam-cloud.py` for production Foundation
preparation/contract tests. See the Cloud decision for boundaries, rollback,
source provenance and required iOS/device validation.
