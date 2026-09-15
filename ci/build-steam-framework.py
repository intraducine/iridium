#!/usr/bin/env python3
"""Build the on-device Steam framework on macOS. No accounts or signing material."""
import argparse
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/packages/steam'
OUTPUT = ROOT / '.build/steam'


def run(*args):
    subprocess.run([str(a) for a in args], cwd=SOURCE, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-only', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Framework compilation requires macOS with Xcode and .NET SDK 10.0.401.')
    if subprocess.check_output(['dotnet', '--version'], cwd=SOURCE, text=True).strip() != '10.0.401':
        parser.error('Use the pinned .NET SDK 10.0.401.')
    host = 'osx-arm64' if platform.machine() == 'arm64' else 'osx-x64'
    run('dotnet', 'run', '--project', 'Iridium.Steam.Tests', '-c', 'Release')
    run('dotnet', 'publish', 'Iridium.Steam.Tests', '-c', 'Release', '-r', host,
        '-p:PublishAot=true', '-o', OUTPUT / 'tests')
    run(OUTPUT / 'tests/Iridium.Steam.Tests')
    frameworks = []
    for rid in (['ios-arm64'] if args.device_only else ['ios-arm64', 'iossimulator-arm64']):
        dest = OUTPUT / rid
        run('dotnet', 'publish', 'Iridium.Steam', '-c', 'Release', '-r', rid,
            '-p:PublishAot=true', '-p:NativeLib=Shared', '-p:PublishAotUsingRuntimePack=true', '-o', dest)
        framework = dest / 'IridiumSteam.framework'
        framework.mkdir(exist_ok=True)
        binary = framework / 'IridiumSteam'
        shutil.copy2(dest / 'Iridium.Steam.dylib', binary)
        run('install_name_tool', '-id', '@rpath/IridiumSteam.framework/IridiumSteam', binary)
        with (framework / 'Info.plist').open('wb') as file:
            plistlib.dump({
                'CFBundleName': 'IridiumSteam', 'CFBundleIdentifier': 'software.iridium.steam-native',
                'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0',
                'CFBundleExecutable': 'IridiumSteam', 'CFBundlePackageType': 'FMWK',
                'MinimumOSVersion': '18.0',
                'CFBundleSupportedPlatforms': ['iPhoneSimulator' if 'simulator' in rid else 'iPhoneOS'],
            }, file)
        shutil.copy2(SOURCE / 'THIRD-PARTY-NOTICES.md', framework)
        symbols = subprocess.check_output(['nm', '-gU', str(binary)], text=True)
        for name in ('initialize', 'submit', 'snapshot', 'take_session', 'free'):
            if '_iridium_steam_' + name not in symbols:
                raise RuntimeError('Missing Steam ABI symbol: ' + name)
        frameworks.extend(['-framework', framework])
    output = ROOT / 'iridium/apps/ios/Frameworks/IridiumSteam.xcframework'
    # Delete only this generated framework, never a caller-supplied path.
    if output.exists():
        if output.is_symlink() or not output.resolve().is_relative_to(ROOT.resolve()):
            raise RuntimeError('Unsafe framework output path')
        shutil.rmtree(output)
    output.parent.mkdir(exist_ok=True)
    run('xcodebuild', '-create-xcframework', *frameworks, '-output', output)
    print('Steam framework built. iOS UI and account/download/device testing remain separate checks.')


if __name__ == '__main__':
    main()
