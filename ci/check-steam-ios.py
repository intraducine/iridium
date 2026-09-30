#!/usr/bin/env python3
"""Run the native Steam tests on iOS Simulator, including anonymous QR/cancel."""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/packages/steam'


def simulator_can_spawn(device):
    """Return whether CoreSimulator can execute a process on this device."""
    try:
        result = subprocess.run(
            ['xcrun', 'simctl', 'spawn', device, 'launchctl', 'list'],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            check=False, timeout=15,
        )
    except subprocess.TimeoutExpired:
        return False, 'spawn timed out'
    reason = (result.stderr or '').strip().replace(device, '<simulator>')
    return result.returncode == 0, reason or f'exit code {result.returncode}'


def wait_for_spawn(device, timeout=180, interval=3):
    """Wait for the simulator capability this test actually needs."""
    deadline = time.monotonic() + timeout
    while True:
        ready, reason = simulator_can_spawn(device)
        if ready:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f'iOS Simulator booted but did not become spawn-ready within {timeout} seconds: {reason}'
            )
        time.sleep(interval)


def prepare_simulator(device, boot):
    """Recover one stalled boot without rerunning tests or resetting user data."""
    if boot:
        subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, timeout=60)
    try:
        wait_for_spawn(device)
    except RuntimeError:
        # Only restart a device this invocation booted. A running developer
        # simulator belongs to its caller, even when it cannot spawn processes.
        if not boot:
            raise
        print('Simulator startup stalled. Checking boot status before one restart.', flush=True)
        try:
            result = subprocess.run(['xcrun', 'simctl', 'bootstatus', device],
                                    capture_output=True, text=True, timeout=15, check=False)
            details = (result.stdout or '') + (result.stderr or '')
        except subprocess.TimeoutExpired as error:
            details = (error.stdout or b'') + (error.stderr or b'')
            if isinstance(details, bytes):
                details = details.decode(errors='replace')
        print(details[-4000:].replace(device, '<simulator>'), flush=True)
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=True, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, timeout=60)
        wait_for_spawn(device)


def select_device(inventory):
    runtimes = [item for item in inventory['runtimes']
                if item.get('isAvailable') and '.iOS-' in item['identifier']]
    if not runtimes:
        raise RuntimeError('An available iOS Simulator runtime is required for Steam verification')
    available = [device for runtime in runtimes
                 for device in inventory['devices'].get(runtime['identifier'], [])
                 if device.get('isAvailable') and device['name'].startswith('iPhone')]
    for state in ('Booted', 'Shutdown'):
        if device := next((item for item in available if item['state'] == state), None):
            print(f"Steam verification simulator: {device['name']} ({state}).", flush=True)
            return device['udid'], state == 'Shutdown', False
    runtime = max(runtimes, key=lambda item: tuple(map(int, item['version'].split('.'))))
    device_type = next(item['identifier'] for item in runtime['supportedDeviceTypes']
                       if item['productFamily'] == 'iPhone')
    device = subprocess.check_output([
        'xcrun', 'simctl', 'create', 'Iridium Steam verification', device_type, runtime['identifier'],
    ], text=True).strip()
    print(f"Created Steam verification simulator for iOS {runtime['version']}.", flush=True)
    return device, True, True


def main():
    output = ROOT / '.build/steam/ios-tests'
    subprocess.run([
        'dotnet', 'publish', 'Iridium.Steam.Tests', '-c', 'Release', '-r', 'iossimulator-arm64',
        '-p:PublishAot=true', '-p:PublishAotUsingRuntimePack=true', '-o', str(output),
    ], cwd=SOURCE, check=True)
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
    device, boot, created = select_device(inventory)
    try:
        # Hosted runners can leave bootstatus waiting on unrelated boot services
        # even after CoreSimulator can execute processes. The Steam verification
        # only requires spawn, so gate on that exact capability instead.
        prepare_simulator(device, boot)
        started = time.monotonic()
        print('Running native Steam checks; process must exit successfully within 300 seconds.', flush=True)
        # Cold hosted simulators can complete the checks near the old two-minute
        # limit. Keep a bounded allowance for process startup and shutdown, and
        # require the actual exit status rather than accepting a PASS log line.
        subprocess.run(['xcrun', 'simctl', 'spawn', device, str(output / 'Iridium.Steam.Tests'), '--network'],
                       check=True, timeout=300)
        print(f'Native Steam checks exited successfully after {time.monotonic() - started:.1f} seconds.', flush=True)
    finally:
        for action, needed in (('shutdown', boot), ('delete', created)):
            if needed:
                try:
                    subprocess.run(['xcrun', 'simctl', action, device], check=False, timeout=60)
                except subprocess.TimeoutExpired:
                    print(f'Simulator cleanup timed out: {action}.', flush=True)
    print('iOS Simulator Steam initialization, protocol, download verification, and QR/cancel checks passed.')


if __name__ == '__main__':
    main()
