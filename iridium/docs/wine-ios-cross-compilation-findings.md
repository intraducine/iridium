# Wine iOS Cross-Compilation Findings

## Date: 2026-03-30

## Summary

Attempted to cross-compile Wine from macOS to iOS (arm64-apple-ios). The build infrastructure was successfully modified to perform cross-compilation, but Wine source code uses macOS-specific APIs that are not available on iOS.

## What Was Changed

### Modified Files

1. **iridium-runtime-sdk/CMakeLists.txt**
   - Changed default platform from `host` (macOS) to `device` (iOS)
   - Added iOS-specific CMake settings for device/simulator builds

2. **iridium-runtime-sdk/scripts/build_runtime_bundle.sh**
   - Updated `build_runtime_host()` to pass iOS-specific cmake arguments
   - Added `RUNTIME_HOST_PLATFORM` variable synced with FEX platform
   - Integrated Wine build into the fork flow with platform support

3. **iridium-wine-ios/iridium/ios/build_install_root.sh**
   - Added `--platform` option (device/simulator/host)
   - Default changed from `host` (macOS) to `device` (iOS)
   - Added iOS cross-compilation configuration with clang/iOS SDK
   - Uses `--host=aarch64-apple-ios` with iOS SDK sysroot

4. **iridium/apps/ios/Scripts/stage_runtime_userland.sh**
   - Updated runtime host path candidates from `arm64-apple-macosx` to `arm64-apple-ios`

### Build Infrastructure Details

The cross-compilation setup:
- Uses macOS wine tools from existing `build-iridium-ios/wine-build` as build tools
- Cross-compiles Wine server, loader, and DLLs for arm64-apple-ios
- Uses iOS SDK at `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.4.sdk`
- Deployment target: iOS 18.0

## Compilation Errors

When attempting to compile Wine for iOS, the following errors occurred:

### 1. Mach Task API Not Available on iOS
```
~/Developer/Repositories/iridium-wine-ios/dlls/ntdll/unix/loader.c:2050:5: error: call to undeclared function 'MPTaskIsPreemptive'
```

### 2. CoreFoundation API Differences
```
~/Developer/Repositories/iridium-wine-ios/dlls/ntdll/unix/loader.c:2056:5: error: call to undeclared function 'CFNotificationCenterGetDistributedCenter'
```

### 3. Disk Label API Not Available on iOS
```
~/Developer/Repositories/iridium-wine-ios/dlls/ntdll/unix/file.c:7227:22: error: use of undeclared identifier 'D_TAPE'
~/Developer/Repositories/iridium-wine-ios/dlls/ntdll/unix/file.c:7230:22: error: use of undeclared identifier 'D_DISK'
```

### 4. CDROM/Device Access APIs
```
make: *** [dlls/ntdll/unix/cdrom.o] Error 1
```

## Root Cause

Wine is designed to run on macOS (and Linux/Windows) as a compatibility layer. It relies on:
- Mach task APIs for threading/process management
- CoreFoundation distributed notification center (macOS-only)
- Disk label APIs for volume management
- Various other macOS-specific frameworks

These APIs are either:
1. Not available on iOS at all
2. Private APIs that Apple restricts on iOS
3. Behave differently between macOS and iOS

## Current Status

The build scripts have been updated to support iOS cross-compilation, but the Wine source code would need significant modifications to work on iOS. For now, the project uses macOS-built Wine binaries which work on iOS Simulator but fail at runtime on physical iOS devices due to platform mismatch.

## Recommendation

See `docs/wine-ios-porting-research.md` for information on what would be required to properly port Wine to iOS.

## References

- Wine macOS-specific code: `dlls/ntdll/unix/loader.c`, `dlls/ntdll/unix/file.c`, `dlls/ntdll/unix/cdrom.c`
- Cross-compilation configuration in `build_install_root.sh`
