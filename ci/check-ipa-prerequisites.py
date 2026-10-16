#!/usr/bin/env python3
"""Fail before Xcode when the current source snapshot cannot build a full IPA."""
from pathlib import Path
import sys
import json
import hashlib

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    "native Steam framework": [
        "iridium/apps/ios/Frameworks/IridiumSteam.xcframework/ios-arm64/IridiumSteam.framework/IridiumSteam",
    ],
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
        "testrepos/Madeira/app/Madeira/arm64ec-windows/d3d12.dll",
        "testrepos/Madeira/app/Madeira/d3d12/libmetalirconverter.dylib",
        "testrepos/Madeira/app/Madeira/d3d12/METAL-SHADER-CONVERTER-AGREEMENT.txt",
        "testrepos/Madeira/app/Madeira/d3d12/LICENSE-metal-shader-converter-headers.txt",
        "testrepos/Madeira/app/Madeira/d3d12/NOTICE.txt",
        "testrepos/Madeira/app/Madeira/arm64ec-windows/ntdll.dll",
        "testrepos/Madeira/app/Madeira/aarch64-windows/ntdll.dll",
        "testrepos/Madeira/app/Madeira/aarch64-windows/xtajit.dll",
        "testrepos/Madeira/app/Madeira/i386-windows/ntdll.dll",
        "testrepos/Madeira/app/Madeira/i386-windows/d3d9.dll",
        "testrepos/Madeira/app/Madeira/prefix-template.tar.gz",
        "testrepos/Madeira/app/Madeira/fonts/tahoma.ttf",
    ],
    "media and input runtime": [
        "iridium/apps/ios/.build/media/libntdll_media.a",
        "iridium/apps/ios/.build/media/libdxmt_media.a",
        "iridium/apps/ios/MediaRuntime/mfreadwrite.dll",
        "iridium/apps/ios/MediaRuntime/winegstreamer.dll",
        "iridium/apps/ios/ControllerRuntime/arm64ec/xinput.dll",
        "iridium/apps/ios/ControllerRuntime/aarch64/iridium-prerequisites.exe",
    ],
    "legacy graphics frameworks": [
        "Amethyst-iOS/Natives/resources/Frameworks/libEGL.framework/libEGL",
        "Amethyst-iOS/Natives/resources/Frameworks/libGLESv2.framework/libGLESv2",
    ],
    "StikJIT framework": [
        "iridium/apps/ios/BuiltinJIT/Vendor/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT",
    ],
}

def required_for_profile(profile):
    if profile not in {'madeira', 'legacy', 'madeira-frontend'}:
        raise ValueError('Unknown runtime package profile: ' + profile)
    if profile == 'madeira-frontend':
        return {'Madeira frontend runtime': [
            'vendor/Madeira/app/Madeira/' + name for name in (
                'libwineserver.a', 'libntdll_unix.a', 'libwin32u_unix.a',
                'libdxmt_combined.a', 'libmadeira_rppairing.a', 'libavcodec.a',
                'libavformat.a', 'libavutil.a', 'libswresample.a',
                'arm64ec-windows/xtajit64.dll', 'aarch64-windows/xtajit.dll',
                'i386-windows/ntdll.dll', 'd3d12/libmetalirconverter.dylib')] }
    return {group: paths for group, paths in REQUIRED.items()
            if profile == 'legacy' or group != 'legacy runtime host and userland'}


def blockers(root, package=False, profile='madeira'):
    result = []
    for group, paths in required_for_profile(profile).items():
        missing = [p for p in paths if not (root / p).is_file() or not (root / p).stat().st_size]
        if missing:
            result.append(f"{group}: missing " + ", ".join(missing))
    if package and profile == 'madeira-frontend':
        output = root / '.build/ipa-output'
        try:
            manifest = json.loads((output / 'COMPONENT-MANIFEST.json').read_text())
            if not manifest['binaries'] or not all(record.get('component') for record in manifest['binaries']):
                raise ValueError('incomplete component mapping')
            if not manifest['static_archives'] or 'vendor/Madeira' not in manifest['revisions']:
                raise ValueError('missing source or link records')
            expected, filename = (output / 'SOURCE-SHA256SUMS').read_text().strip().split()
            if filename != 'Iridium-corresponding-source.tar.gz':
                raise ValueError('unexpected source archive')
            with (output / filename).open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                    raise ValueError('source checksum mismatch')
        except (OSError, ValueError, KeyError, TypeError):
            result.append('Matching source archive or component manifest is missing or invalid')
    records = ['binary-release-blockers.json']
    if package:
        records.append('binary-package-blockers.json')
    for name in records:
        try:
            pending = json.loads((root / 'ci' / name).read_text())
            if not isinstance(pending, list) or not all(isinstance(item, str) and item for item in pending):
                raise ValueError('invalid blocker record')
            result.extend('Source/license audit: ' + item for item in pending)
        except (OSError, ValueError):
            result.append('Source/license audit record is missing or invalid: ' + name)
    return result

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', action='store_true')
    parser.add_argument('--profile', choices=('madeira', 'legacy', 'madeira-frontend'), default='madeira')
    args = parser.parse_args()
    problems = blockers(ROOT, package=args.package, profile=args.profile)
    if problems:
        print("Unsigned IPA packaging is blocked." if args.package else
              "Unsigned IPA build is not ready. No app was built or uploaded.")
        for problem in problems:
            print(f"- {problem}")
        print("See docs/actions-ipa.md. Do not upload local binaries or signing files to bypass this check.")
        sys.exit(1)
    print("Initial IPA prerequisites are present. Xcode and the package audit must still pass.")
