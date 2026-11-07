# SPDX-License-Identifier: AGPL-3.0-only
"""Run pinned protocol fixtures against the source that Iridium actually stages."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iridium/apps/ios/App'
HOST = ROOT / 'vendor/Madeira/tests/host'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class StoreProtocolTests(unittest.TestCase):
    def run_fixture(self, name, original, replacement):
        path = HOST / ('check-' + name + '.py')
        source = path.read_text()
        self.assertEqual(source.count(original), 1, 'Pinned driver changed; review its source path')
        source = source.replace(original, replacement)
        # Keep fixture paths relative to their pinned driver. Only app source paths change.
        driver = 'import sys;exec(compile(sys.stdin.read(),sys.argv[1],"exec"),{"__name__":"__main__","__file__":sys.argv[1]})'
        result = subprocess.run([sys.executable, '-c', driver, str(path)], input=source, text=True,
            capture_output=True, timeout=180, env=dict(os.environ, LEGENDARY_SRC=str(HOST / 'no-legendary')))
        self.assertEqual(result.returncode, 0, result.stdout[-5000:] + result.stderr[-5000:])

    def test_steam_lan_request_status_and_chunk_transfer(self):
        self.run_fixture('steam-lan-peer', "steam = root / 'app/Madeira/SwiftSteam'",
                         'steam = Path(' + repr(str(APP / 'Steam/Transport')) + ')')

    def test_ea_crypto_archive_and_licence_formats(self):
        self.run_fixture('ea-formats', 'SRC = ROOT / "app" / "Madeira" / "SwiftEA" / "EAFormats.swift"',
                         'SRC = Path(' + repr(str(APP / 'Stores/EA/Transport/EAFormats.swift')) + ')')

    def test_epic_cloud_planner_and_chunk_formats(self):
        self.run_fixture('epic-cloud', 'EPIC = ROOT / "app" / "Madeira" / "SwiftEpic"',
                         'EPIC = Path(' + repr(str(APP / 'Stores/Epic/Transport')) + ')')

    def test_gyro_axes_and_turbo_timing(self):
        self.run_fixture('pad-assist', "source = (root / 'app/Madeira/PadAssist.swift').read_text()",
                         'source = Path(' + repr(str(APP / 'Controls/PadAssist.swift')) + ').read_text()')
