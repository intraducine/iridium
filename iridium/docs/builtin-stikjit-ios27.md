# Built-in JIT on iOS 18 and later

Built-in JIT runs StikJIT in an app extension. Enable it in Settings > Launch
Support when using standalone Iridium. Iridium targets iOS 18 or later for this
build. It also requires debugging permission, a valid remote-pairing file, and
a connected LocalDevVPN.

Upstream StikJIT documents its helper framework for iOS 17.4 or later. Iridium
keeps an iOS 18 floor because the main app, Madeira runtime, and native iOS build
are already scoped to iOS 18 or later. On devices where TXM/SPTM is absent,
attaching and detaching the debugger is sufficient to enable JIT. Where TXM/SPTM
is present, the existing iOS 26 breakpoint protocol remains responsible for
preparing executable regions before they are used.

Import the pairing file in Launch Support, connect LocalDevVPN, then play a game.
When using Iridium inside LiveContainer, use external StikDebug through
LiveContainer2.

The sideloading IPA's main app has an anonymous ad-hoc signature containing only
`com.apple.developer.kernel.increased-memory-limit=true`; its helper is unsigned.
This carrier supplies no debugging permission or provisioning profile. Sign the
app and helper with your supported setup; built-in JIT checks `get-task-allow`
on the installed app. Confirm increased-memory-limit in both the final app
signature and profile. In LiveContainer, the host process's effective rights
apply. Packaging checks do not establish recipient signing or device behavior.

External JIT is selected under Launch Support → External JIT App. Automatic
tries LiveContainer2, StikDebug, LiveContainer, then a LiveContainer3 fallback.
Built-in and external requests have bounded waits. Cancellation may leave a
helper alive if it could own a stopped thread; follow the app's restart request.

## Implementation

The host launches `IridiumJITHelper.appex` and accepts an XPC connection only from
its extension process. The helper validates the target host process and sends
an initial connection message before attachment. StikJIT runs on a serial queue.

The pairing file is protected and excluded from backups. Its bytes pass over
XPC to a temporary protected file, which the helper removes after use. Pairing
contents must not appear in application logs.

The extension decoder permits `NSXPCListenerEndpoint` and delegates other class
validation to the system. The Madeira script implements the iOS 26 breakpoint
protocol used for TXM/SPTM executable-region preparation. It reports attachment
readiness; the host then prepares executable memory and detaches before starting
Wine. On systems without TXM/SPTM, debugger attachment and detach do not require
that executable-region preparation protocol. A readiness message alone does not
establish game compatibility.

Use the error shown by the app to correct pairing, VPN, permission, or helper
connection failures. Do not terminate a helper that may own a stopped host thread.

## Build and validation

Use the repository build instructions in [setup](setup.md) and the
[IPA workflow](../../docs/actions-ipa.md) for current helper/app compilation and
package validation. The retained component script
`iridium/apps/ios/BuiltinJIT/Tests/check.sh` assumes Xcode is installed at
`/Applications/Xcode-beta.app` and overrides `DEVELOPER_DIR`; it is not a portable
check for any selected Xcode installation. In that environment, its checks cover
pairing validation, XPC decoding, the initial handshake, and launch recovery,
plus iOS 18 metadata and helper packaging when passed an app bundle.

No physical-device compatibility is implied by these build checks. Built-in JIT
still needs device validation on the supported iOS 18-25 path and on iOS 26+
TXM/SPTM devices, including helper launch, debugger attachment, executable-region
preparation where required, Wine startup, and rendered gameplay.
The [2026-10-03 baseline build](https://github.com/intraducine/iridium/actions/runs/37096956724)
passed helper/app compilation and package checks at
`25e5763ee1c56b731f9df235e7bbea4f9f0cafba`, still configured as 0.1.1. It is
not a 0.2.0 device or recipient-signing verification.

## Sources and notices

Pinned sources and component notices are recorded in
[StikJITNotices/SOURCES.md](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
Preserve the MPL, GPL, AGPL, and dependency notices that apply to distributed
components. Follow the repository's source and binary distribution checks.
