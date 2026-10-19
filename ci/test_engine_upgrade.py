"""Compile real native headers; upstream UI churn must not affect compatibility."""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('engine_upgrade', ROOT / 'ci/check-engine-upgrade.py')
upgrade = importlib.util.module_from_spec(spec); spec.loader.exec_module(upgrade)


@unittest.skipUnless(shutil.which('xcrun') and (ROOT / 'vendor/Madeira/app').is_dir(), 'Apple SDK and local Madeira source required')
class EngineUpgradeTests(unittest.TestCase):
    def test_ui_replacement_is_compatible_native_changes_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory)
            source = ROOT / 'vendor/Madeira/app/Madeira'
            for path in source.rglob('*.h'):
                target = candidate / 'app/Madeira' / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, target)
            # These names/contents need not be valid Swift: engine UI is not an input.
            (candidate / 'app/Madeira/ContentView.swift').write_text('arbitrary upstream redesign')
            (candidate / 'app/Madeira/Library.swift').write_text('upstream renamed its models')
            self.assertEqual(upgrade.check(candidate)['result'], 'compatible')
            header = candidate / 'app/Madeira/Madeira-Bridging-Header.h'
            original = header.read_text()
            changes = [('uint64_t madeira_get_present_count(void);', 'double madeira_get_present_count(void);'),
                       ('uint64_t madeira_get_present_count(void);', '')]
            for before, after in changes:
                header.write_text(original.replace(before, after))
                with self.subTest(after=after), self.assertRaisesRegex(ValueError, 'madeira_get_present_count'):
                    upgrade.check(candidate)
            header.write_text(original)
            cursor = candidate / 'app/Madeira/Winios/WiniosCursor.h'
            cursor.write_text(cursor.read_text().replace('struct winios_direct_cursor_state {', 'struct winios_direct_cursor_state {\n double incompatible_field;'))
            with self.assertRaisesRegex(ValueError, 'winios_direct_cursor_state'): upgrade.check(candidate)


if __name__ == '__main__': unittest.main()
