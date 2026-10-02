#!/usr/bin/env python3
"""Compile and execute the actual Foundation-only queue and persistence tests."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='iridium-steam-queue-') as directory:
        executable = Path(directory) / 'queue-checks'
        subprocess.run([
            'swiftc', '-swift-version', '6', '-parse-as-library',
            str(ROOT / 'iridium/apps/ios/Iridium/SteamDownloadQueue.swift'),
            str(ROOT / 'iridium/apps/ios/SteamDownloadTests/QueueChecks.swift'),
            '-o', str(executable),
        ], check=True, timeout=180)
        subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    main()
