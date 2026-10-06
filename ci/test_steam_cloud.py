"""Run the production Foundation-only Steam Cloud regression fixtures."""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SteamCloudTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_preparation_and_contracts(self):
        subprocess.run(['python3', str(ROOT / 'ci/check-steam-cloud.py')], check=True, timeout=240)


if __name__ == '__main__':
    unittest.main()
