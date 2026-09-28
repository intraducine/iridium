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
- Downloads pause when backgrounded. Explicitly resume the saved queue job after reopening;
  valid chunks are reused, including after a process restart.
- Installs live in Application Support, excluded from device backups. Each build
  has a separate directory. Existing imported games and their saves stay in place.
- The initial selection is the public Windows 64-bit/neutral English build.
  Unprotected branch, language,
  32/64-bit depot and DLC selection are available in Download Options. Password-protected
  branches, Cloud saves, automatic update scheduling and desktop Steam IPC are not implemented.
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
source/relink requirements. The source collector retains the new dependencies;
the binary inventory must be updated against a real compiled iOS framework before
an IPA containing this module is distributed.


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
