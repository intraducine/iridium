# Steam on device

This module implements direct Steam client sign-in, Steam Guard/QR authentication,
authenticated library retrieval, and resumable Windows depot downloads. The iOS
shell exposes it under **Add Game → Download from Steam**. No PC or API key is used.

## Build and test

Use .NET SDK **10.0.401**. From this directory:

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
The rest of Iridium's runtime prerequisites still apply. Tests and framework
creation do not sign, publish, or establish device compatibility.

## Behavior and boundaries

- Passwords are held only during authentication. Saved sessions go to an iOS
  Keychain item with `WhenUnlockedThisDeviceOnly`; sign-out deletes the item.
- Only one account operation/download runs at a time. Download uses up to four
  concurrent chunks, pooled buffers, TLS CDN endpoints, bounded retries, and
  manifest/file hashes. No simulated account or download fallback is used.
- Downloads pause when backgrounded. Select the same game to resume after reopening;
  valid chunks are reused, including after a process restart.
- Installs live in Application Support, excluded from device backups. Each build
  has a separate directory. Existing imported games and their saves stay in place.
- The initial selection is the public Windows 64-bit/neutral English build.
  Encrypted beta branches, 32-bit-only depots, conflicting depot overlays, Cloud
  saves, automatic updates, and desktop Steam IPC are not implemented.
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
