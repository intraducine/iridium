#!/usr/bin/env python3
"""Fetch the pinned SteamKit source and apply Iridium's iOS compatibility patch."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def prepare():
    item = next(item for item in json.loads((ROOT / 'ci/steam-source-inputs.json').read_text())
                if item['name'] == 'steamkit-3.4.0')
    revision = item['revision']
    if item['repository'] != 'SteamRE/SteamKit' or revision != '1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7':
        raise ValueError('Review the iOS patch before changing the SteamKit source pin')
    target = ROOT / '.build/steamkit'
    if target.is_symlink() or not target.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError('Unsafe SteamKit source directory')
    target.mkdir(parents=True, exist_ok=True)

    def git(*args):
        return subprocess.run(['git', '-C', str(target), *args], check=True, capture_output=True, text=True)

    if not (target / '.git').exists():
        git('init', '--quiet')
        git('fetch', '--quiet', '--depth=1', 'https://github.com/SteamRE/SteamKit.git', revision)
        git('checkout', '--quiet', '--detach', 'FETCH_HEAD')
    if git('rev-parse', 'HEAD').stdout.strip() != revision:
        raise ValueError('Existing SteamKit checkout does not match its source pin')
    patch = str(ROOT / 'ci/patches/steamkit-ios-process-start.patch')
    already_applied = subprocess.run(['git', '-C', str(target), 'apply', '--reverse', '--check', patch],
                                     capture_output=True).returncode == 0
    if not already_applied:
        git('apply', '--check', patch)
        git('apply', patch)
    # No other upstream source edits may silently enter the framework.
    changed = git('diff', '--name-only').stdout.splitlines()
    if changed != ['SteamKit2/SteamKit2/Steam/SteamClient/SteamClient.cs']:
        raise ValueError('Unexpected edits in the SteamKit source checkout')
    print('Prepared SteamKit 3.4.0 with the iOS process-start compatibility patch.')


if __name__ == '__main__':
    prepare()
