# First Frame Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hollow Knight produce at least one visible frame in the iOS fullscreen runtime player without regressing the now-working viewer launch handoff.

**Architecture:** Treat this as a pipeline problem with four boundaries: app launch package -> embedded host -> Wine iOS driver -> shared framebuffer viewer. The current evidence proves the app viewer, runtime handoff, input bridge, and FEX execution are alive; the missing evidence is whether the guest ever enters a supported OpenGL present path. The fix sequence must first add high-signal diagnostics, then force/verify an OpenGL launch path for Unity titles, then only modify the `wineios.drv` present implementation if the trace proves that path is active but broken.

**Tech Stack:** Swift/iOS app (`iridium`), SwiftPM runtime tests, C++ embedded runtime host (`iridium-runtime-sdk`), Wine iOS driver C code (`iridium-wine-ios`), iOS device logs via shared `iridium-runtime.log`.

---

## Current Evidence

- New log: `/Users/developer/Downloads/iridium-runtime.log`, modified `2026-05-02 15:31:14 EDT`.
- Build 20 is present: `Version 20 warning-gated-launch`.
- Viewer handoff works: `runtimeSessionExecutor: fullscreenHandoff ... terminalStatus=running`.
- Launch succeeds: `executeLaunch: Launch succeeded for hollow_knight ... status=running`.
- Input bridge works: `runtimePlayer: inputEventWritten ... failures=0`.
- No frames arrive: repeated `runtimePlayer: framePollNoChange ... presentedFrames=0`.
- Watchdog reason: `no guest frame was presented through the ... metalOpenGLFallback graphics path`.
- Host env includes `IRIDIUM_WINE_IOS_GRAPHICS_DRIVER=wineios.drv` and `IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH=.../framebuffer.bgra`.
- `wine-debug.log` is absent and the runtime log does not show `wineios.drv` OpenGL traces such as `opengl framebuffer presentation driver registered`, `opengl drawable created`, or `opengl framebuffer presented frame=`.

## File Structure

- Modify `/Users/developer/Developer/Repositories/iridium-runtime-sdk/src/runtime_host_core.cpp`
  - Log the launch arguments and every `IRIDIUM_WINE_IOS_*` env key needed to diagnose graphics handoff.
- Modify `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/bridge.c`
  - Ensure the trace file is created as soon as bridge config is loaded, even before OpenGL initializes.
- Modify `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/opengl.c`
  - Add explicit trace points for OpenGL init, surface creation, EGL pbuffer creation, swap, readback, framebuffer write, and failure reasons.
- Modify `/Users/developer/Developer/Repositories/iridium/packages/profiles/Sources/IridiumProfiles/Profiles.swift`
  - Add a specific OpenGL Unity launch argument profile only if diagnostics show Hollow Knight is not entering Wine OpenGL.
- Modify `/Users/developer/Developer/Repositories/iridium/packages/profiles/Tests/IridiumProfilesTests/IridiumProfilesTests.swift`
  - Test the Unity/OpenGL launch argument policy.
- Modify `/Users/developer/Developer/Repositories/iridium/apps/ios/Iridium/IridiumApp.swift`, `/Users/developer/Developer/Repositories/iridium/apps/ios/Iridium/Info.plist`, and `/Users/developer/Developer/Repositories/iridium/apps/ios/project.yml`
  - Bump the app build marker/version before each device-verification build so logs identify the tested implementation.

## Task 1: Add Pipeline Diagnostics Only

**Files:**
- Modify: `/Users/developer/Developer/Repositories/iridium-runtime-sdk/src/runtime_host_core.cpp`
- Modify: `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/bridge.c`
- Modify: `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/opengl.c`

- [ ] **Step 1: Log complete bridge environment at host launch**

In `runtime_host_core.cpp`, expand the existing probe block near `run()` so the host log includes the surface id, dimensions, bridge root, input path, audio path, renderer preset, and launch arguments.

Expected log keys after this change:

```text
launch-arg[0]=...
launch-env IRIDIUM_WINE_IOS_SURFACE_ID=...
launch-env IRIDIUM_WINE_IOS_SURFACE_WIDTH=960
launch-env IRIDIUM_WINE_IOS_SURFACE_HEIGHT=540
launch-env IRIDIUM_WINE_IOS_BRIDGE_ROOT=...
launch-env IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH=...
launch-env IRIDIUM_WINE_IOS_AUDIO_STATE_PATH=...
launch-env IRIDIUM_RENDERER_PRESET=metalOpenGLFallback
launch-env IRIDIUM_RUNTIME_GRAPHICS_STACK=metalOpenGLFallback
```

- [ ] **Step 2: Make `wineios-trace.log` exist before OpenGL init**

In `bridge.c`, after `wineiosdrv_load_bridge_configuration()` has a valid `configuration->trace_path`, append a line to that file. The line should include session id, framebuffer path, surface size, graphics driver, and bridge config path.

Expected trace line:

```text
bridge-config-loaded session=<uuid> framebuffer=<path>/framebuffer.bgra size=960x540 driver=wineios.drv config=<path>/iridium-playable-session.json
```

- [ ] **Step 3: Add OpenGL driver trace checkpoints**

In `opengl.c`, ensure `wineiosdrv_OpenGLInit()` logs:

```text
opengl-init-enter version=<version> egl=<present|missing>
opengl-init-registered
opengl-init-unavailable reason=no-egl-backend
```

Ensure `wineios_surface_create()` logs:

```text
opengl-surface-create-enter hwnd=<value> format=<value>
opengl-surface-create-config-missing
opengl-surface-create-framebuffer-opened path=<path> size=960x540
opengl-surface-create-pbuffer-failed size=960x540
opengl-surface-create-success size=960x540 path=<path>
```

Ensure `wineios_drawable_swap()` and `wineios_present_current_gl_frame()` log:

```text
opengl-swap-enter drawable=<value>
opengl-readback-enter size=960x540
opengl-readback-complete bytes=2073600
opengl-framebuffer-write-complete frame=1 path=<path>
opengl-framebuffer-write-failed frame=1 path=<path>
```

- [ ] **Step 4: Build only the Wine userland/driver path**

Run from `/Users/developer/Developer/Repositories/iridium-runtime-sdk`:

```bash
swift test --filter IridiumRuntimeHostSDKTests
```

Expected: existing runtime SDK tests pass.

- [ ] **Step 5: Package/import the runtime bundle**

Run the existing local runtime packaging/import workflow used for build 19/20. Expected manifest version should change from `2026.05.02-wine-debug-capped` to a new diagnostic identifier such as `2026.05.02-first-frame-diagnostics`.

- [ ] **Step 6: Build app build 21**

Update:

```text
apps/ios/Iridium/IridiumApp.swift -> Version 21 first-frame-diagnostics
apps/ios/Iridium/Info.plist -> CFBundleVersion 21
apps/ios/project.yml -> CFBundleVersion: "21"
```

Run:

```bash
swift test
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and iOS generic build succeeds.

- [ ] **Step 7: Device run classification**

Install/run build 21. Classify the new log before changing behavior:

```text
Case A: no "opengl-init-enter"
  Wine never loaded the iOS OpenGL driver. Investigate driver registration/loading.

Case B: "opengl-init-registered" exists but no "opengl-surface-create-enter"
  The game is not using Wine OpenGL. Move to Task 2.

Case C: "opengl-surface-create-success" exists but no "opengl-swap-enter"
  A GL drawable exists, but the game never swaps. Investigate Unity/window mode or WGL surface ownership.

Case D: "opengl-swap-enter" exists but no "opengl-framebuffer-write-complete"
  The driver present path is active but readback/write is broken. Move to Task 3.

Case E: "opengl-framebuffer-write-complete" exists but app still logs presentedFrames=0
  The app framebuffer signature/load logic is wrong. Move to Task 4.
```

- [ ] **Step 8: Commit diagnostics**

Commit all diagnostic changes separately:

```bash
git -C /Users/developer/Developer/Repositories/iridium-runtime-sdk add src/runtime_host_core.cpp Tests
git -C /Users/developer/Developer/Repositories/iridium-runtime-sdk commit -m "Log iOS graphics bridge handoff details"

git -C /Users/developer/Developer/Repositories/iridium-wine-ios add dlls/wineios.drv
git -C /Users/developer/Developer/Repositories/iridium-wine-ios commit -m "Trace Wine iOS OpenGL presentation path"

git -C /Users/developer/Developer/Repositories/iridium add apps/ios/Iridium/IridiumApp.swift apps/ios/Iridium/Info.plist apps/ios/project.yml
git -C /Users/developer/Developer/Repositories/iridium commit -m "Bump app for first-frame diagnostics"
```

## Task 2: If Hollow Knight Is Not Entering OpenGL, Force the Unity OpenGL Path

**Files:**
- Modify: `/Users/developer/Developer/Repositories/iridium/packages/profiles/Sources/IridiumProfiles/Profiles.swift`
- Modify: `/Users/developer/Developer/Repositories/iridium/packages/profiles/Tests/IridiumProfilesTests/IridiumProfilesTests.swift`
- Modify: `/Users/developer/Developer/Repositories/iridium/apps/ios/Iridium/IridiumApp.swift`
- Modify: `/Users/developer/Developer/Repositories/iridium/apps/ios/Iridium/Info.plist`
- Modify: `/Users/developer/Developer/Repositories/iridium/apps/ios/project.yml`

- [ ] **Step 1: Add a failing profile test**

Add a test asserting the OpenGL-only profile includes Unity-compatible launch arguments:

```swift
func testLightweightProfileForcesUnityOpenGLPresentation() {
    let profile = BuiltInCompatibilityProfiles.compatibilityProfile(slug: "lightweight-default")
    XCTAssertEqual(
        profile?.launchArguments,
        ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"]
    )
}
```

Run:

```bash
swift test --filter IridiumProfilesTests/testLightweightProfileForcesUnityOpenGLPresentation
```

Expected before implementation: fail because current args are `["--windowed"]`.

- [ ] **Step 2: Change only the OpenGL-first profile arguments**

In `Profiles.swift`, change `lightweight-default` launch arguments from:

```swift
launchArguments: ["--windowed"],
```

to:

```swift
launchArguments: ["-force-opengl", "-screen-fullscreen", "0", "-popupwindow"],
```

Do not change balanced/performance/heavy profiles in this task.

- [ ] **Step 3: Verify launch package includes the new args**

Run:

```bash
swift test --filter IridiumProfilesTests/testLightweightProfileForcesUnityOpenGLPresentation
swift test --filter IridiumRuntimeTests/testLaunchPlanning
```

Expected: profile test passes; any affected launch-planning expectations must be updated only where they explicitly expect `--windowed` for lightweight OpenGL.

- [ ] **Step 4: Build app build 22**

Update build marker/version:

```text
Version 22 unity-opengl-launch
CFBundleVersion 22
```

Run:

```bash
swift test
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and iOS generic build succeeds.

- [ ] **Step 5: Device verification**

Install/run build 22. Required success evidence:

```text
App build identity: marker=Version 22 unity-opengl-launch
launch-arg[0]=-force-opengl
opengl-init-registered
opengl-surface-create-success
opengl-framebuffer-write-complete frame=1
runtimePlayer: framePresented ... count=1
```

If `opengl-init-registered` is present but `opengl-surface-create-success` is not, stop and inspect the Wine trace before changing app code.

## Task 3: If OpenGL Swap Happens but No Framebuffer Write, Fix `wineios.drv` Present

**Files:**
- Modify: `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/opengl.c`
- Modify: `/Users/developer/Developer/Repositories/iridium-wine-ios/dlls/wineios.drv/window.c`

- [ ] **Step 1: Confirm the failing branch from diagnostics**

Only start this task if the device log contains:

```text
opengl-surface-create-success
opengl-swap-enter
```

and does not contain:

```text
opengl-framebuffer-write-complete frame=1
```

- [ ] **Step 2: Fix exactly one present-path failure**

Use the diagnostic line to pick one fix:

```text
opengl-readback-failed
  Fix GL readback state or buffer selection.

opengl-framebuffer-write-failed
  Fix file open/truncate/write/flush path.

opengl-pixel-size-mismatch
  Fix expected byte count or surface dimensions.
```

Do not modify Unity args or app viewer code in the same commit.

- [ ] **Step 3: Verify with a device log**

Required success evidence:

```text
opengl-framebuffer-write-complete frame=1
runtimePlayer: framePresented ... count=1
```

- [ ] **Step 4: Commit driver fix**

```bash
git -C /Users/developer/Developer/Repositories/iridium-wine-ios add dlls/wineios.drv/opengl.c dlls/wineios.drv/window.c
git -C /Users/developer/Developer/Repositories/iridium-wine-ios commit -m "Fix Wine iOS OpenGL framebuffer present"
```

## Task 4: If Frames Are Written but Swift Still Shows Blank, Fix Viewer Polling

**Files:**
- Modify: `/Users/developer/Developer/Repositories/iridium/apps/ios/Iridium/Views/RuntimePlayerView.swift`
- Modify: `/Users/developer/Developer/Repositories/iridium/apps/ios/IridiumAppSupportTests/IridiumAppSupportTests.swift`

- [ ] **Step 1: Confirm this is the failing branch**

Only start this task if the device log contains:

```text
opengl-framebuffer-write-complete frame=1
```

but does not contain:

```text
runtimePlayer: framePresented
```

- [ ] **Step 2: Add a failing Swift test for framebuffer signature changes**

Add a test that creates a temporary `960x540x4` framebuffer file, records the initial signature, rewrites the same-size file with new bytes, and asserts the signature changes. The current code uses `size-modifiedAt`, so this test should catch file timestamp resolution problems if writes occur too quickly.

- [ ] **Step 3: Fix signature calculation**

Change the viewer signature from `size-modifiedAt` to include a cheap content sample, for example first 64 bytes, middle 64 bytes, last 64 bytes, and modification time.

- [ ] **Step 4: Verify**

Run:

```bash
swift test --filter IridiumAppSupportTests
swift test
xcodebuild -project apps/ios/Iridium.xcodeproj -scheme Iridium -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and iOS generic build succeeds.

## Completion Criteria

- A new device log from build 21 or later classifies the failing graphics boundary.
- If the boundary is "not entering OpenGL", build 22 must show Hollow Knight launched with OpenGL-forcing args.
- Final successful device log must include:

```text
runtimeSessionExecutor: fullscreenHandoff ... terminalStatus=running
opengl-framebuffer-write-complete frame=1
runtimePlayer: framePresented ... count=1
```

- Repos must be clean and pushed:

```bash
git -C /Users/developer/Developer/Repositories/iridium status --short --branch
git -C /Users/developer/Developer/Repositories/iridium-runtime-sdk status --short --branch
git -C /Users/developer/Developer/Repositories/iridium-wine-ios status --short --branch
```

Expected: each repo shows `## main...origin/main` with no changed files.

## Self-Review

- Spec coverage: the plan addresses the user's requirement to avoid aimless fixes by requiring classification before behavior changes.
- Highest-risk unknown: whether Hollow Knight supports Unity `-force-opengl` on this Windows build. The diagnostic branch will prove or disprove that without changing the driver blindly.
- No direct device control is required from Codex; the user can run the built app and provide the shared log.
