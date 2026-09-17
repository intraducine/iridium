# Native Steam authentication and downloads

## Decision

Add an on-device SteamKit2 module exposed through a small C ABI and presented by
SwiftUI. NativeAOT compiles it into an embedded iOS framework. It connects directly
to Steam over TLS/WebSocket, authenticates with credentials and Steam Guard or QR,
lists the authenticated user's games, and requests authorized Windows depots.
There is no companion PC, hosted service, developer API key, or anonymous ownership
fallback. The legacy simulated Steam clients remain isolated from this UI.

Swift owns presentation and Keychain persistence. The module owns a single account
connection and a single active operation. Snapshots contain no credentials. The
refresh token crosses a separate one-time ABI call into a non-synchronizing,
device-only Keychain item. Passwords and guard codes are not persisted. Sign-out
removes the saved session; it does not delete game files or saves.

## Installation and efficiency

Game storage is Application Support/SteamGames/app-id/build-id/content. Partials
live beside it. The current public Windows 64-bit/neutral, English depots are
selected; protected branches and 32-bit-only depots are not supported. Steam checks
depot access; inaccessible optional DLC is skipped. Shared depots resolve through
their parent app. Conflicting depot files fail with an explanation.

At most four chunks download concurrently. Buffers are pooled and bounded; files
are written by offset. Resume re-hashes existing chunks. SHA-1 checks match Steam's
manifest format and protect integrity, not publisher identity. Completed files
are promoted only after their file hash passes. Paths, symlinks, offsets, lengths,
disk space, and whole-file hashes are checked. A complete receipt appears only
after the entire install verifies. The user selects an executable and registers
it in the durable Iridium library without copying the download again. Existing
runtime/JIT readiness and game launch remain authoritative.

Downloads pause on backgrounding. iOS does not provide an unlimited background
execution grant for a Steam protocol session. Returning to the foreground or
relaunching allows resume by selecting the same game. Current in-flight HTTP
requests have SteamKit's bounded request/body timeouts. No new chunk writes occur
after cancellation is observed. Source files and saves are never erased to repair
an interruption.

## Alternatives

Steam OpenID supplies identity but not depot download authorization. A PC companion
would violate the standalone requirement. Running the whole Windows Steam client
adds runtime and browser-process overhead and relies on unverified Wine support.
A fresh Swift Steam protocol implementation would duplicate authentication,
crypto, compression, and protocol maintenance. SteamKit therefore supplies the
protocol layer, with explicit NativeAOT serializer roots and regression checks.

## Migration and rollback

Existing imported games and legacy Steam fixtures are unchanged. Only Steam entries
marked `steam-native-download` are exposed alongside existing imported games.
No persisted library schema changes are required. Removing the integration returns
the UI to manual import; keep SteamGames directories and Keychain data until the
user deliberately removes them. Build-version folders prevent overwriting files
used by a previously installed game. Game updates/save migration are not automated.

## Validation and limitations

Run the managed and NativeAOT tests in `iridium/packages/steam`. A native compiler
success alone is insufficient: protobuf serialization and real CM operations must
also execute. The framework script runs the native regression executable before
producing iOS slices. iOS compilation, account/Guard flows, real depot downloads,
Keychain behavior, SwiftUI accessibility, suspension, and physical-device game
execution each need their own evidence. Steam DRM/Steamworks IPC and anti-cheat are
not supplied by this download session; games requiring the desktop Steam client
may fail to launch. The integration does not remove those requirements.
