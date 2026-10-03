# Manual Validation Runbook

This runbook covers manual acceptance of licensed Windows games and native Steam downloads. Test the current Madeira app separately from the earlier embedded-runtime harness.

Use licensed game payloads and authorized accounts. These checks are intended
for manual device labs, not CI.

## Scope

Test the selected runtime with licensed game files on a physical device.
Record rendering, input, audio, save persistence, and shutdown separately.
For legacy embedded-runtime tests, build the matching host, device, or simulator
translator artifact before starting the checks below.

## Preconditions

- Select the exact source commit and build run. Verify the actual app/helper
  version and build number, matching source/checksums, package audit, and final
  recipient signature/profile before installing. The anonymous memory carrier
  alone does not grant installation, debugging, or increased-memory rights.
- Prepare the current app through the root [IPA guide](../../docs/actions-ipa.md)
  and `stikjit.yml`, with green source and relevant build checks. Do not use the
  earlier `Iridium.xcodeproj` as evidence for the complete release app.
- Configure JIT using the [JIT guide](builtin-stikjit-ios27.md). Built-in JIT
  needs standalone hosting, debugging permission, pairing, and LocalDevVPN;
  LiveContainer uses external JIT. Follow restart requests.
- Preserve existing games, prefixes, and saves. Use a separate test installation
  and enough storage for downloads plus retained repair/update copies.

## Current Madeira app acceptance

1. Import a licensed game through Add Game, select its executable, and Play.
2. Observe changing frames and guest interaction; a player screen or running
   status alone is insufficient. Test touch, keyboard/mouse, and controller
   paths separately where available.
3. Verify audible output, save/reload across a fresh process, shutdown, app
   switching, and relaunch. Record faults for the specific game and device.
4. Exercise Game Options → Run Installer with a valid game prerequisite. Check
   setup prompts, success recording, cancellation, late runtime exit, and the
   restart-required path. A close timeout is not confirmed shutdown.
5. Repeat signing/JIT checks for standalone and LiveContainer hosting. For
   standalone, confirm increased-memory-limit in Iridium's final app signature
   and profile. Hosted execution uses the container process's effective rights;
   importing the guest IPA does not grant them.

## Earlier embedded-runtime checks

The following package, capability, allocator, and harness checks exercise the
retained earlier runtime. They are component-development procedures, not a
replacement for current Madeira release/device acceptance.

- Earlier package and app checks:
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform host`
  - `ctest --test-dir ../iridium-fex-ios/build-iridium-ios-host --output-on-failure`
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform device`
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform simulator`
  - `swift test`
  - `xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'platform=iOS Simulator,name=<available-simulator-name>' test` when simulator coverage is relevant to the slice under test
  - If you need to discover a valid simulator name first, run `xcrun simctl list devices available`
- Provision and validate the earlier bundled runtime in Settings when testing it.
- Its external JIT provider may gate queued launch resume.

## Physical-Device JIT Proof Loop

Use this exact loop to prove the permanent split RX/RW allocator path on a physical iPhone.

On iOS 26/27 TXM devices, keep the StikDebug script attached for the full runtime session. FEX requests debugger ownership for every executable view as code caches are created; a one-time readiness-page preparation is not sufficient. Non-TXM iOS 26 devices and the iOS 27 `iPad8,11`/`iPad8,12` models deliberately skip this breakpoint protocol. Do not enable the legacy exception-port guard during the TXM flow because the attached helper owns those ports.

1. Rebuild the fork artifacts and app inputs:
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform host`
  - `ctest --test-dir ../iridium-fex-ios/build-iridium-ios-host --output-on-failure`
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform device`
  - `../iridium-fex-ios/iridium/ios/build_embedded_translator.sh --platform simulator`
  - `swift test`
2. Install a fresh debug build of Iridium on the phone so `host-capabilities.json` includes debug diagnostics such as `allocatorBackend`.
3. Provision the bundled runtime in Settings and confirm the runtime bundle appears under managed storage.
4. Negative control: launch the app normally, without the external debugger/JIT workflow.
  - Refresh host capabilities in-app.
  - Confirm `host-capabilities.json` reports `jitStatus = required`.
  - Confirm the launch summary says `No external debugger/JIT session detected.`
5. Negative control: launch through the external debugger/JIT workflow, but force allocator failure if you need to verify the unavailable path.
  - Use the chosen lab workflow to inject a failure mode or a forced unavailable probe result.
  - Refresh host capabilities in-app.
  - Confirm `host-capabilities.json` reports `jitStatus = unavailable`.
  - Confirm the launch summary says `Debugger session detected, but executable code allocation still failed ...` with a stage-specific detail.
6. Positive control: launch through the intended external debugger/JIT workflow with the rebuilt device artifact.
  - On a TXM device, use StikDebug 3.1.6 or newer from Iridium's in-app action. Confirm the URL targets the current PID and StikDebug remains attached. AltJIT, JitStreamer, and SideStore do not provide the persistent executable-region callback required by this path.
  - On a non-TXM device, confirm the ordinary debugger-backed flow does not stop on `brk #0xf00d`.
  - Refresh host capabilities in-app.
  - Confirm `host-capabilities.json` reports `jitStatus = ready`.
  - Confirm `allocatorBackend = split-rx-rw-debugger` in the debug capability record.
  - Confirm the runtime host log records `jit-backend=split-rx-rw-debugger` and `jit-summary=Runtime ready.`
7. Attempt launch of the lightweight OpenGL x64 title.
  - Confirm the bundled-device backend no longer blocks on JIT readiness.
  - Confirm the session advances beyond readiness gating into real execution.

## First-Playable iPhone Session Validation

Use this flow after the JIT proof loop succeeds.

1. Refresh host capabilities in-app before launch.
  - Confirm `launchReady = true`.
  - Confirm `presentationReadiness = ready`.
  - Confirm `inputReadiness = ready`.
  - Confirm `audioReadiness = ready`.
  - Confirm `playabilityReady = true`.
  - Confirm none of those readiness fields depends on a development-only override.
2. Launch the lightweight OpenGL x64 title from the library detail screen.
  - Confirm the library flow presents the dedicated fullscreen runtime player instead of leaving the user in the list/detail UI.
  - Confirm the session status enters `.running` before any terminal result is recorded.
3. Inspect runtime artifacts for the launched session.
  - Confirm the runtime host log records `session-acquired`, render/input/audio service registration, and later `session-released`.
  - Confirm the registered render/input/audio handles match the active player session id.
  - Confirm the prefix config contains `config/iridium-playable-session.json`.
  - Confirm the direct-launch environment file exports `IRIDIUM_WINE_IOS_BRIDGE_CONFIG`, `IRIDIUM_WINE_IOS_GRAPHICS_DRIVER=wineios.drv`, and `IRIDIUM_WINE_IOS_AUDIO_DRIVER=winecoreaudio.drv`.
4. Exercise the first-playable interactions.
  - Confirm the first frame reaches the fullscreen player surface.
  - Confirm touch or controller input changes the guest state.
  - Confirm audio initializes and continues after entering `.running`.
5. Dismiss, background, or let the session terminate.
  - Confirm the fullscreen player releases ownership cleanly.
  - Confirm launch history records terminal completion or failure without orphaning the session.

## Harness Usage

The repo-owned validation harness logic lives in `packages/runtime` as `ValidationHarness`.
For command-line use, the executable entrypoint is `IridiumAcceptanceHarness`.

For deterministic lab artifacts, use the executable harness:

```bash
swift run IridiumAcceptanceHarness \
  --title "Sample Imported Game" \
  --source manualImport \
  --install-path /absolute/path/to/SampleImportedGame \
  --output /absolute/path/to/import-validation.json
```

Optional:

- `--executable /absolute/path/to/Game.exe` to force the launch target when candidate ranking should be overridden during validation.
- `--app-id <steam-app-id>` when recording a Steam-sourced validation artifact for a title that should resolve against a specific Steam app id.

The shipped product path is the bundled local device runtime. `IridiumBridgeHost` and provider-backed transport remain internal debugging tools and are not required for the manual-import validation flow.

For each lab run, record:

- title
- source (`manualImport` or `steam`)
- managed install path
- selected executable path
- runtime bundle id/version
- resolved runtime policy
- host capability snapshot showing `launchReady`, `playabilityReady`, `presentationReadiness`, `inputReadiness`, and `audioReadiness`
- launch result
- persisted runtime failure or host session id
- launch ticket path
- prefix manifest path
- runtime session log path
- telemetry path
- install execution summary for Steam-sourced runs when that path is explicitly under test

The harness output should be attached to the validation note alongside:

- embedded host capability snapshot from `hostCapabilitySnapshot`
- prefix manifest path
- runtime host ticket path
- runtime host log path
- telemetry path

## Manual Import Flow

Use this flow for at least one real Windows game folder.

1. Import the folder from the Library flow.
2. Confirm candidate executable ranking is sane and override the executable manually once during testing.
3. Verify the title is copied into managed storage.
4. Confirm the prefix record stores:
   - bundle id/version
   - title fingerprint
   - manifest path/version
   - bootstrap status
5. Launch the title and confirm the runtime host submits a direct executable launch with `IRIDIUM_NO_DESKTOP=1`.
6. If the run fails, confirm `LaunchHistoryEntry` and runtime failure persistence capture the concrete reason.

Expected result:

- The imported title is either accepted on a resolved broad-catalog policy or rejected with a structured failure reason, never by falling back to a desktop shell.
- If JIT is not available yet, the launch should queue durably instead of pretending to execute.
- If the device artifact or JIT path is still missing, the invariant is that the UI, launch history, and host log all surface the same concrete blocker.

## Steam Flow

Use the current native **Downloads** tab. Real-account acceptance remains
outstanding; public metadata, QR challenge/cancel, and fixtures are narrower checks.

1. In Downloads → Steam, test password, each available Guard method, QR refresh/
   cancel, saved-session restore, expired tokens, sign-out, and account switching.
   Confirm passwords/tokens are absent from queue JSON and exported diagnostics.
2. Select an owned game and exercise language, unprotected branch, 32/64-bit
   depots, and owned DLC. Queue multiple jobs; verify priority, pause/resume,
   retry/cancel, and account scoping.
3. Interrupt the network, background, and terminate the app. Reopen and resume
   explicitly; verify partial chunks and final files rather than trusting progress.
4. Exercise low and unknown storage warnings. Download Anyway permits one
   attempt; pause, ordinary retry, and relaunch must check storage again. Real
   out-of-space and verification errors must still fail.
5. In Installed, select Add to Library and the executable, then Play through
   Madeira. Record rendering, input, audio, saves, and shutdown separately.
6. Check for Updates and Repair or Update. Confirm older game files remain,
   registration preserves settings/prefix/save mappings, and game-local saves
   are copied manually when needed.
7. In a disposable test copy, distinguish Remove from Downloads (history only)
   from Delete Game Files (selected copy and library entry, including game-local
   saves). Confirm separate Windows-profile saves remain.
8. Check VoiceOver, large text, orientation, keyboard and controller navigation,
   and both standalone and LiveContainer hosting.

## Acceptance

- Direct launch succeeds or fails with a structured persisted reason.
- Game launch does not fall back to a Windows desktop or shell. Prerequisite
  setup may intentionally display Windows installer prompts before the game.
- Prefix bootstrap succeeds before launch submission.
- Runtime evidence references the imported executable fingerprint or the registered Steam artifact.
- Explicit host-capability gating, storage gating, and whitelist policy are enforced when the selected runtime policy requires them.

## Record the result

Record the app build, selected runtime, device model, OS version, game, input
method, exact source commit/run, steps, and observed results and limits. Keep
private device identifiers and raw logs out
of public reports. Follow the repository release policy for acceptance.
