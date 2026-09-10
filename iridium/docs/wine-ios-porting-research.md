# Wine iOS Porting Research

## Date: 2026-03-30

## Executive Summary

Porting Wine to iOS is a significant undertaking that would require extensive source code modifications. While cross-compilation infrastructure can be set up (as demonstrated), the fundamental challenge is that Wine relies heavily on macOS-specific APIs that don't exist or behave differently on iOS.

## Current Wine Architecture

Wine translates Windows API calls to POSIX calls (Linux/macOS). On macOS, this means translating Windows syscalls to:
- Mach task APIs
- BSD system calls
- CoreFoundation / AppKit frameworks
- IOKit for device access

## Key Challenges for iOS Porting

### 1. Mach Task API Limitations

Wine uses Mach task APIs for threading and process management:
```c
// Current Wine code (dlls/ntdll/unix/loader.c)
MPTaskIsPreemptive(MPCurrentTaskID());
MPCurrentTaskID();
```

**iOS Issue:** These Mach APIs exist on iOS but:
- `MPTaskIsPreemptive()` is deprecated and may behave differently
- Multiprocessing APIs are restricted on iOS
- Sandbox restrictions prevent certain operations

**Mitigation Options:**
- Replace with GCD (Grand Central Dispatch) equivalents
- Use pthreads directly
- Implement custom thread management

### 2. CoreFoundation Distributed Notifications

```c
// Current Wine code
CFNotificationCenterGetDistributedCenter();
```

**iOS Issue:** The distributed notification center is available but:
- Sandboxed apps cannot use distributed notifications
- IPC mechanisms are severely limited on iOS

**Mitigation Options:**
- Use Darwin notifications instead
- Implement custom IPC via XPC

### 3. Disk Label APIs

```c
// Current Wine code (dlls/ntdll/unix/file.c)
D_TAPE
D_DISK
D_TTY
```

**iOS Issue:** These BSD disk label constants don't exist on iOS.

**Mitigation Options:**
- Conditionally exclude these checks for iOS
- Implement alternative disk type detection

### 4. CDROM/Device Access

```c
// dlls/ntdll/unix/cdrom.c
```

**iOS Issue:** Direct CDROM access is not possible on iOS due to:
- No CD/DVD drives on iOS devices
- App Sandbox restrictions
- IOKit limitations on iOS

**Mitigation Options:**
- Stub out CDROM functions
- Redirect to virtual光驱

### 5. File System Differences

iOS has a more restricted file system:
- No direct access to `/dev`
- Sandboxed app containers
- Restricted symlink behavior
- No support for certain BSD file operations

### 6. JIT/Code Generation Restrictions

> **2026-07 correction:** The entitlement guidance below is historical and is not the Iridium sideloaded-device design. Apple's general MAP_JIT guidance is for supported hardened-runtime contexts, while iOS browser JIT is restricted to BrowserEngineKit entitlements. Iridium instead uses an attached debugger helper and split RX/RW mappings. Only TXM devices use StikDebug's persistent executable-region callback; non-TXM iOS 26/27 devices must not execute that breakpoint protocol. See Apple's [JIT porting guidance](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon), [BrowserEngineKit JIT restrictions](https://developer.apple.com/documentation/browserenginekit/protecting-code-compiled-just-in-time), and [StikDebug 3.1.6](https://github.com/StephenDev0/StikDebug/releases/tag/3.1.6).

**iOS Issue:** ordinary sideloaded apps cannot grant themselves executable-memory permission:
- A signed app and `get-task-allow` still do not replace the external debugger/JIT workflow.
- BrowserEngineKit JIT capabilities are restricted to approved browser-engine use and are not a general game-runtime entitlement.

**Mitigation Options:**
- Use a compatible external debugger helper and fail closed when its required callback is absent.
- Use AOT (ahead-of-time) compilation where the guest/runtime architecture permits it.
- Implement an interpreted fallback where performance and compatibility remain acceptable.

## Required Source Modifications

### Priority 1: Core NT Layer

Files needing modification:
- `dlls/ntdll/unix/loader.c` - Thread/process management
- `dlls/ntdll/unix/file.c` - File system operations
- `dlls/ntdll/unix/registry.c` - Registry operations
- `dlls/ntdll/unix/cdrom.c` - Device access

### Priority 2: Unix Library

Files needing modification:
- `dlls/ntdll/unix/sync.c` - Synchronization primitives
- `dlls/ntdll/unix/signal.c` - Signal handling
- `dlls/ntdll/unix/mapping.c` - Memory mapping

### Priority 3: Wine Server

The wineserver needs complete rewrite for iOS:
- Use XPC for inter-process communication
- Replace Mach ports with iOS equivalents
- Implement as XPC service

## Alternative Approaches

### Option A: Minimal iOS Wine

Create a stripped-down Wine variant:
- Target only basic Win32 APIs
- Implement direct-launch only (no explorer)
- Use FEX for x86_64 → ARM64 translation (already in use)

**Pros:** Simpler implementation
**Cons:** Limited application compatibility

### Option B: FEX-Centered Architecture

Build on existing FEX (x86_64 emulator) work:
- FEX handles CPU emulation
- Implement minimal Windows API translation layer
- Focus on direct-launch games

**Pros:** Leverages existing work
**Cons:** Still requires Windows API implementation

### Option C: Wine on Android Study

Study Winlator (Wine + Box86/Box64 on Android):
- Winlator shows it's possible to run Wine on ARM
- Uses Box86/Box64 for x86 translation
- Integrates with Android's different syscall model

**Reference:** https://github.com/brunodev85/winlator (17k stars)

### Option D: Custom Translation Layer

Build a purpose-built Windows runtime for iOS:
- Don't use Wine at all
- Implement only needed Windows APIs
- Focus on game compatibility

**Pros:** Full control, optimized for iOS
**Cons:** Massive undertaking

## Existing iOS Ports (References)

### XeniOS (Xbox 360 Emulator)
- https://github.com/xenios-jp/XeniOS
- Shows iOS porting is feasible for emulation projects
- 145 stars, active development
- iOS-specific fork of Xenia emulator

### Dolphin iOS
- https://github.com/OatmealDome/dolphin-ios
- GameCube/Wii emulator on iOS
- Shows ARM64 JIT on iOS is possible with proper entitlements

## Recommended Path Forward

### Phase 1: Research & Prototyping
1. Create iOS-specific fork of iridium-wine-ios
2. Stub out problematic functions (CDROM, disk labels)
3. Replace Mach APIs with GCD equivalents
4. Test with simple Windows executables

### Phase 2: Core Implementation
1. Implement wineserver as XPC service
2. Integrate and validate the external debugger-backed JIT flow, including TXM/non-TXM capability selection
3. Implement missing file system operations
4. Add FEX integration for x86_64 support

### Phase 3: Testing & Optimization
1. Test with Wine test suite
2. Benchmark and optimize hot paths
3. Add game-specific workarounds

## Resources Needed

- C/C++ developer with macOS/iOS kernel experience
- Knowledge of Mach kernel APIs
- Understanding of iOS Sandbox limitations
- ARM64 assembly knowledge for JIT implementation

## Timeline Estimate

| Phase | Task | Estimate |
|-------|------|----------|
| 1 | Research & stubbing | 2-3 months |
| 2 | Core implementation | 6-9 months |
| 3 | Testing & polish | 3-6 months |
| **Total** | | **11-18 months** |

## References

- Wine Source: https://github.com/wine-mirror/wine
- Winlator: https://github.com/brunodev85/winlator
- Box86/Box64: https://github.com/ptitSeb/box64
- XeniOS: https://github.com/xenios-jp/XeniOS
- iOS Syscall Table: https://gist.github.com/aemmitt-ns/bda9feda782016c295d694378f11158d

## Conclusion

Porting Wine to iOS is technically challenging but possible. The main obstacles are:
1. macOS-specific APIs not available on iOS
2. Sandboxing restrictions
3. JIT/Code generation limitations

A pragmatic approach would be to build on the existing FEX work and create a minimal Windows API translation layer rather than attempting a full Wine port.

---

*This document is for research purposes. A sideloaded build still requires external signing/debugger infrastructure for JIT; app code alone cannot remove that platform boundary.*
