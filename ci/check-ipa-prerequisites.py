#!/usr/bin/env python3
"""Fail before Xcode when the current source snapshot cannot build a full IPA."""
from pathlib import Path
import sys
import json

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    "legacy runtime host and userland": [
        "iridium-runtime-sdk/build/iridium-runtime-base/manifest.json",
        "iridium-runtime-sdk/build/iridium-runtime-base/Runtime/runtime-host.bin",
        "iridium-runtime-sdk/build/iridium-runtime-base/Translator/x64-jit.bin",
        "iridium-runtime-sdk/build/iridium-runtime-base/Userland/wine-userland.tar.zst",
    ],
    "legacy native link libraries": [
        "iridium-fex-ios/build-iridium-ios-iphoneos/artifacts/libiridium-fex-ios-embedded.a",
        "iridium-wine-ios/build-iridium-ios/wine-build-iphoneos/artifacts/libiridium-wineserver-ios.a",
    ],
    "Madeira native runtime": [
        "testrepos/Madeira/app/Madeira/libwineserver.a",
        "testrepos/Madeira/app/Madeira/libwin32u_unix.a",
        "testrepos/Madeira/app/Madeira/libntdll_unix.a",
        "testrepos/Madeira/app/Madeira/libdxmt_combined.a",
        "testrepos/Madeira/app/Madeira/libgnutls.a",
        "testrepos/Madeira/app/Madeira/libhogweed.a",
        "testrepos/Madeira/app/Madeira/libnettle.a",
        "testrepos/Madeira/app/Madeira/libgmp.a",
        "testrepos/Madeira/FEX/build-ios/FEXCore/Source/libFEXCore.a",
        "testrepos/Madeira/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a",
    ],
    "Windows modules and clean prefix": [
        "testrepos/Madeira/app/Madeira/arm64ec-windows/ntdll.dll",
        "testrepos/Madeira/app/Madeira/aarch64-windows/ntdll.dll",
        "testrepos/Madeira/app/Madeira/prefix-template.tar.gz",
    ],
    "media and input runtime": [
        "iridium/apps/ios/.build/media/libntdll_media.a",
        "iridium/apps/ios/.build/media/libdxmt_media.a",
        "iridium/apps/ios/MediaRuntime/mfreadwrite.dll",
        "iridium/apps/ios/MediaRuntime/winegstreamer.dll",
        "iridium/apps/ios/ControllerRuntime/arm64ec/xinput.dll",
    ],
    "legacy graphics frameworks": [
        "Amethyst-iOS/Natives/resources/Frameworks/libEGL.framework/libEGL",
        "Amethyst-iOS/Natives/resources/Frameworks/libGLESv2.framework/libGLESv2",
    ],
    "StikJIT framework": [
        "iridium/apps/ios/BuiltinJIT/Vendor/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT",
    ],
}

def blockers(root):
    result = []
    for group, paths in REQUIRED.items():
        missing = [p for p in paths if not (root / p).is_file() or not (root / p).stat().st_size]
        if missing:
            result.append(f"{group}: {len(missing)} required file(s) missing")
    record = root / "ci/binary-release-blockers.json"
    try:
        pending = json.loads(record.read_text())
        if not isinstance(pending, list) or not all(isinstance(item, str) and item for item in pending):
            raise ValueError("invalid blocker record")
        result.extend("Source/license audit: " + item for item in pending)
    except (OSError, ValueError):
        result.append("StikJIT and dependency source/license audit record is missing or invalid")
    return result

if __name__ == "__main__":
    problems = blockers(ROOT)
    if problems:
        print("Unsigned IPA build is not ready. No app was built or uploaded.")
        for problem in problems:
            print(f"- {problem}")
        print("See docs/actions-ipa.md. Do not upload local binaries or signing files to bypass this check.")
        sys.exit(1)
    print("Initial IPA prerequisites are present. Xcode and the package audit must still pass.")
