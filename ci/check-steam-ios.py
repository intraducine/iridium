#!/usr/bin/env python3
"""Run the native Steam tests on iOS Simulator, including anonymous QR/cancel."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/packages/steam'


def main():
    output = ROOT / '.build/steam/ios-tests'
    subprocess.run([
        'dotnet', 'publish', 'Iridium.Steam.Tests', '-c', 'Release', '-r', 'iossimulator-arm64',
        '-p:PublishAot=true', '-p:PublishAotUsingRuntimePack=true', '-o', str(output),
    ], cwd=SOURCE, check=True)
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
    runtime = next((item for item in inventory['runtimes']
                    if item.get('isAvailable') and '.iOS-' in item['identifier']), None)
    if runtime is None:
        raise RuntimeError('An available iOS Simulator runtime is required for Steam verification')
    device_type = next(item['identifier'] for item in inventory['devicetypes']
                       if item['name'].startswith('iPhone'))
    device = subprocess.check_output([
        'xcrun', 'simctl', 'create', 'Iridium Steam verification', device_type, runtime['identifier'],
    ], text=True).strip()
    try:
        subprocess.run(['xcrun', 'simctl', 'boot', device], check=True)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True, timeout=180)
        subprocess.run(['xcrun', 'simctl', 'spawn', device, str(output / 'Iridium.Steam.Tests'), '--network'],
                       check=True, timeout=120)
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False)
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=False)
    print('iOS Simulator Steam initialization, protocol, download verification, and QR/cancel checks passed.')


if __name__ == '__main__':
    main()
