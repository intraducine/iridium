# Integration into the current main checkout, 2026-09-10

Applied the feature changes from `3c51958` and `ab93525` to the current
`main` working tree. Did not import the older `e715f10` interface snapshot.
Existing uncommitted work remains intact; no merge commit was created.
The two LibraryShelf syntax corrections were already present.

The new settings use the current controller menu controls and suspend app
controller routing while the native pairing-file picker is open.
The opt-in build is `apps/ios/IridiumStikJIT.xcodeproj`, generated from
`apps/ios/stikjit.yml`. The existing Madeira build remains available.

Validation: full unsigned iOS 27 build passed, pairing and attachment regression
checks passed, helper packaging and license notice checks passed.
No installation or physical-device JIT test was performed for this integration.
The following experiment notes describe the source branch and its earlier work.

---

# Built-in StikJIT experiment for iOS 27+

Branch: `feature/builtin-stikjit-ios27`.
Worktree: `/Users/developer/Developer/Repositories/iridium-stikjit-ios27`.
Baseline: `e715f10`, an isolated snapshot of the main checkout's existing work.
The original checkout and its in-progress edits were not changed.

## Current result

The full Iridium application and helper build with Xcode 27 (27A5218g), for
arm64 iPhoneOS 27. Both application and extension require iOS 27.0 or later.
The experimental path is opt-in under Settings > Launch Support. External
StikDebug and its existing LiveContainer2 routing remain the default.

No experimental app was installed. The final build is unsigned. Extension
launch, pairing import UI, debugger attachment, executable memory preparation,
and gameplay through this helper have NOT been verified on an iPhone. A build
and packaging check are not evidence that private extension APIs still work.

## Integration

- `stikjit.yml` includes the existing Madeira application build.
- The host starts `IridiumJITHelper.appex` using private NSExtension APIs.
- The host accepts only an XPC connection from the extension PID returned by iOS.
  The helper accepts a target PID only if it matches the connecting host.
- StikJIT 1.5.0 runs only inside the helper, on one serial background queue.
- A protected, backup-excluded pairing file is imported into
  `Documents/StikJIT/pairingFile.plist`. The helper receives its bytes over XPC,
  writes a temporary protected file, and removes that file when the call ends.
  Pairing contents and raw StikJIT responses are not added to application logs.
- The helper uses a bundled copy of the current Madeira script. Two local changes
  reject a failed attach and emit one exact readiness marker before its BRK loop.
  That marker permits memory preparation; it does not report a ready runtime.
- Madeira retains its existing 512 MiB pool allocation, writable mapping, and
  detach sequence. Wine starts only after detach returns and StikJIT confirms
  completion. The chosen provider is captured at launch, so a later setting
  change cannot redirect an active launch.
- Timeouts, connection loss, missing entitlements, missing pairing, and unsupported
  hosting produce errors. There is no silent switch to another provider. After
  a helper attempt fails, restart the process before retrying. A possibly attached
  helper is not forcibly killed while it may own a stopped host thread.
- Built-in operation is blocked inside LiveContainer. LocalDevVPN is still needed.

## Xcode 27 and transport findings

The pinned upstream archive SHA-256 is
`444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85`.
`BuiltinJIT/prepare.py` verifies this digest before extraction. It strips redundant
`StikJIT.` self-module qualification in the two Swift interfaces: the module and
public enum share that name, and Xcode 27 rejected the original interfaces.
The Mach-O implementation is unchanged. The script also supplies the framework's
missing Info.plist, needed for bundle signing. This passed the final app build.

A local test rejected the first proposed transport: NSXPCListenerEndpoint can only
be encoded by NSXPCCoder, not NSKeyedArchiver. The implementation therefore sends
the endpoint through native XPC. Its extension entry point permits only that exact
endpoint class in Apple's private decoder; all other class checks call Apple's
original implementation. It does not use the reference proposal's blanket decoder
bypass. It fails closed if that private method or extension entry point is missing.
This narrow exception and extension registration must be tested on the actual OS.

Two missing Swift `label:` keywords in LibraryShelf.swift were fixed only in this
worktree to compile the copied, in-progress interface snapshot. No layout changes
were made for this experiment.

The experiment's build flag reuses existing FEX and Wine archives. It does not
run build scripts that modify the sibling repositories. The two ignored media
archives in `apps/ios/.build/media` were copied from the existing Iridium build.

## Reproduce

Run from this worktree, with the existing sibling runtime dependencies available:

```sh
python3 apps/ios/BuiltinJIT/prepare.py
xcodegen generate --spec apps/ios/stikjit.yml
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project apps/ios/IridiumStikJIT.xcodeproj -scheme Iridium \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.build/stikjit-app" CODE_SIGNING_ALLOWED=NO build
sh apps/ios/BuiltinJIT/Tests/check.sh \
  .build/stikjit-app/Build/Products/Debug-iphoneos/Iridium.app
```

Tests passed: empty/malformed/oversized/incomplete pairing rejection; accepted
script attachment; rejected/disconnected attachment does not report readiness;
Objective-C launcher compilation; iOS 27 minimum versions; helper entry-point
symbol; bundled custom script; framework metadata; license notices; and StikJIT
embedded only in the helper. Final full app build passed.

## Device acceptance still required

1. Sign both bundles and framework; inspect the final host `get-task-allow` and
   validate all nested signatures before installation.
2. Confirm extension registration and authenticated XPC connection on iOS 27.
3. Exercise missing VPN, wrong pairing, interrupted helper, and restart recovery.
4. Verify the imported pairing UI, native toggle, and touch/controller/keyboard
   access. The existing interface was not redesigned; no new visual effects,
   hidden entrance content, decorative cards, or fonts were introduced. Runtime
   visual and interaction checks remain pending, including contrast on device.
5. Prove actual JIT allocation and detach using the existing DX11 cube, followed by
   game rendering and input. Repeat from a fresh process and after an iPhone reboot.
6. Keep the external provider available until this path passes device tests.

## Source and license notices

- StikJIT 1.5.0: https://github.com/StikDebug/StikJIT/tree/1.5.0 (MPL-2.0).
  Preserve its notices and make covered source and local interface changes
  available under applicable MPL terms when distributing.
- Madeira script: https://github.com/willfaust/Madeira (GPL-3.0-or-later), copied
  from the current local runtime; original script SHA-256:
  `71887a1c6dc7549f0d3cef0272a42e8fa4c6678bac556a3eb2b4f24baa58b0e1`.
  The two helper-specific edits are marked. Preserve corresponding-source and
  license obligations for the combined runtime if distributing it.
- idevice: https://github.com/jkcoxson/idevice (MIT notice retained). The framework
  release vendors its static library without a precise source revision or a full
  dependency bill of materials. Before external distribution, verify that exact
  provenance and the retained licenses of its bundled universal/legacy scripts.
- Extension API reference, not copied implementation:
  https://github.com/OatmealDome/dolphin-ios/pull/277.
- Integration guide: https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md.

Full MPL, GPL, and idevice notices are bundled in StikJITNotices. No top-level
project license was changed. This branch was not pushed or published.

## Existing-phone baseline captured before disconnect

Read-only export: `local-diagnostics/stikjit-baseline-2026-09-09/` (ignored by Git).
Includes Iridium runtime log, current/previous Madeira logs, the 23:03 CPU resource
report, the 22:54 system memory-pressure report, device/install metadata, and a
SHA-256 manifest. The device reports iOS 27.0, build 24A5390f. These are logs from
the previously installed external-JIT app, not proof of the new helper. No app
was started, stopped, installed, or removed. No pairing credentials or saves were
copied. StikDebug guest logs were not found in the accessible LiveContainer
containers.

## Recheck, 2026-09-10

Found and fixed an incorrect pairing validator. The first version required
Lockdown HostID/certificate fields, but this StikJIT path reads remote-pairing
identifier/public_key/private_key fields. An upstream-shaped synthetic remote
record failed before the correction. The new validator checks the remote keys
and their correspondence; it accepts both remote-only records and iloader's
combined records. Legacy-only files fail early. No real credentials were used.

Regression tests passed for XML and binary records, absent/malformed/mismatched
keys, and invalid sizes. The complete iOS 27 application rebuilt successfully.
Packaging checks were rerun against that rebuilt app and passed. The branch
remains experimental and unsigned; no new app was installed, and actual phone
helper activation is still unverified.

Format sources checked live:
https://github.com/jkcoxson/idevice/blob/master/idevice/src/remote_pairing/rp_pairing_file.rs
https://github.com/nab138/iloader/blob/main/src-tauri/src/pairing.rs
