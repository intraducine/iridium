#!/usr/bin/env python3
"""Build an isolated simulator harness around the production Phase 3 adapters."""
import importlib.util
import plistlib
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build():
    spec = importlib.util.spec_from_file_location('phase3_smoke_components', ROOT / 'ci/build-phase3.py')
    components = importlib.util.module_from_spec(spec); spec.loader.exec_module(components)
    output = ROOT / '.build/phase3-smoke'; app = output / 'IridiumPhase3Smoke.app'
    app.mkdir(parents=True, exist_ok=True); (app / 'Frameworks').mkdir(exist_ok=True)
    for engine, binary in [('host', 'libIridiumRetroPlayer.dylib'), ('dolphin', 'libIridiumDolphin.dylib'),
                          ('azahar', 'azahar_libretro.dylib'), ('play', 'play_libretro_ios.dylib'), ('flycast', 'flycast_libretro.dylib')]:
        source = ROOT / '.build/phase3' / engine / 'iphonesimulator' / binary
        components.audit(source, 'iphonesimulator', native=engine in ('host', 'dolphin'))
        shutil.copy2(source, app / 'Frameworks' / binary)
    shutil.copytree(ROOT / '.build/phase3/dolphin/iphonesimulator/assets/Sys', app / 'Sys', dirs_exist_ok=True)
    shutil.copy2(ROOT / '.build/phase3/play/iphonesimulator/assets/GameConfig.xml', app / 'GameConfig.xml')
    info = dict(CFBundleIdentifier='software.iridium.phase3smoke', CFBundleExecutable='IridiumPhase3Smoke',
                CFBundleName='Phase 3 Smoke', CFBundlePackageType='APPL', CFBundleVersion='1',
                CFBundleShortVersionString='1.0', MinimumOSVersion='18.0',
                UILaunchScreen={}, LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2],
                UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
    subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios18.0-simulator',
                    '-isysroot', sdk, '-I', str(bridge), '-c', str(bridge / 'IRPhase3.c'), '-o', str(output / 'bridge.o')], check=True)
    subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-target', 'arm64-apple-ios18.0-simulator', '-sdk', sdk, '-module-cache-path', str(output / 'cache'),
                    '-import-objc-header', str(bridge / 'IRPhase3.h'), str(ROOT / 'ci/input/Phase3Smoke.swift'),
                    str(output / 'bridge.o'), '-Xlinker', '-rpath', '-Xlinker', '@executable_path/Frameworks',
                    '-o', str(app / 'IridiumPhase3Smoke')], check=True)
    for path in sorted((app / 'Frameworks').glob('*.dylib')):
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    print(app)


if __name__ == '__main__': build()
