"""App staging uses maintained sources and rejects stale or modified output."""
from pathlib import Path
import hashlib
import json
import tempfile
import unittest
import iridium_app_sources as app


class OwnedAppTests(unittest.TestCase):
    def test_stage_replaces_arbitrary_upstream_ui_and_verifies_owned_output(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            (stage / 'Madeira/Winios').mkdir(parents=True)
            (stage / 'MadeiraJITHelper').mkdir()
            (stage / 'Madeira/RenamedUpstreamUI.swift').write_text('broken Swift from future upstream')
            (stage / 'MadeiraJITHelper/obsolete.swift').write_text('old helper')
            names = app.stage(stage)
            app.verify(stage)
            self.assertIn('IridiumApp.swift', names)
            self.assertFalse((stage / 'Madeira/RenamedUpstreamUI.swift').exists())
            self.assertFalse((stage / 'MadeiraJITHelper/obsolete.swift').exists())
            stale = stage / 'Madeira/MenuAudio/obsolete.wav'
            stale.write_bytes(b'obsolete cue')
            app.stage(stage)
            self.assertFalse(stale.exists())
            cue = stage / 'Madeira/MenuAudio/focus1.wav'
            original = cue.read_bytes()
            cue.write_bytes(b'broken sound')
            with self.assertRaisesRegex(ValueError, 'MenuAudio/focus1.wav'): app.verify(stage)
            cue.write_bytes(original)
            native = stage / 'Madeira/IridiumMadeiraServices.swift'
            native.write_text(native.read_text() + '\n// stale output')
            with self.assertRaisesRegex(ValueError, 'IridiumMadeiraServices'): app.verify(stage)

    def test_source_ownership_is_complete_and_no_engine_checkout_supplies_swift(self):
        paths = app.main_sources()
        self.assertEqual(len(paths), len({path.name for path in paths}))
        self.assertTrue(all('vendor' not in path.relative_to(app.ROOT).parts for path in paths))
        for units in app.ownership()['logicalUnits'].values():
            for unit in units: self.assertTrue((app.ROOT / app.APP / unit['path']).is_file())
        source = app.logical_source('Library.swift')
        self.assertIn('struct LibraryEntry: Codable', source)
        self.assertIn('extension LibraryEntry', source)
        self.assertIn('final class LibraryModel', source)

    def test_historical_migration_inputs_have_fixed_provenance(self):
        fixture = app.ROOT / 'ci/fixtures/madeira-build43'
        record = json.loads((fixture / 'source.json').read_text())
        self.assertEqual(record['revision'], app.ownership()['derivedFrom']['revision'])
        for name, digest in record['sha256'].items():
            self.assertEqual(hashlib.sha256((fixture / name).read_bytes()).hexdigest(), digest, name)
        self.assertFalse(any('fixtures' in path.parts for path in app.main_sources()))


if __name__ == '__main__': unittest.main()
