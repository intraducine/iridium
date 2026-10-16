"""Licensed resource replacement fails closed and preserves older deliveries."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import importlib.util
import ppsspp_atlas_resources as atlas


class AtlasResourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.origin = self.root / 'vendor/PPSSPP/assets'
        self.replacements = self.root / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases'
        self.origin.mkdir(parents=True); self.replacements.mkdir(parents=True)
        (self.root / 'ci').mkdir()
        lock = {'inputs': []}
        (self.root / 'ci/psp-atlas-inputs.json').write_text(json.dumps(lock))
        resources = {}
        for name in atlas.FILES:
            original, replacement = ('original-' + name).encode(), ('replacement-' + name).encode()
            (self.origin / name).write_bytes(original)
            (self.replacements / name).write_bytes(replacement)
            resources[name] = {'originalSHA256': hashlib.sha256(original).hexdigest(),
                               'sha256': hashlib.sha256(replacement).hexdigest()}
        self.receipt = {'revision': atlas.REVISION, 'resources': resources, 'fontInputs': lock}
        (self.root / 'ci/psp-atlas-resources.json').write_text(json.dumps(self.receipt))

    def stage(self):
        import shutil
        target = self.root / 'stage'
        shutil.copytree(self.origin, target / 'vendor/PPSSPP/assets')
        shutil.copytree(self.replacements, target / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases')
        return target

    def test_source_delivery_uses_owned_assets_even_after_omitting_old_atlases(self):
        for path in self.origin.iterdir(): path.unlink()
        plan = atlas.replacement_plan(self.origin, self.root)
        self.assertEqual(set(plan), set(atlas.FILES))
        self.assertEqual(set(plan.values()), set(self.replacements.iterdir()))

    def test_changed_or_symbolic_replacements_are_rejected(self):
        name = atlas.FILES[-1]
        (self.replacements / name).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Licensed atlas changed'):
            atlas.replacement_plan(self.origin, self.root)
        (self.replacements / name).unlink()
        (self.replacements / name).symlink_to(self.origin / name)
        with self.assertRaisesRegex(ValueError, 'Licensed atlas changed'):
            atlas.replacement_plan(self.origin, self.root)

    def test_changed_upstream_input_is_rejected(self):
        (self.origin / atlas.FILES[0]).write_bytes(b'new upstream')
        with self.assertRaisesRegex(ValueError, 'Upstream atlas changed'):
            atlas.replacement_plan(self.origin, self.root)

    def test_current_source_removes_exact_old_bytes_and_retains_replacements(self):
        stage = self.stage()
        result = atlas.collect_inputs(stage, {'licensedAtlases': self.receipt}, self.root)
        self.assertEqual(len(result['exclusions']), 4)
        self.assertEqual(list((stage / 'vendor/PPSSPP/assets').iterdir()), [])
        self.assertEqual(len(list((stage / 'iridium/apps/ios/RuntimeSupport/PPSSPPAtlases').iterdir())), 4)
        self.assertEqual(len(list(self.origin.iterdir())), 4)

    def test_source_exclusions_are_atomic_when_any_old_resource_differs(self):
        stage = self.stage()
        (stage / 'vendor/PPSSPP/assets' / atlas.FILES[-1]).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Unreviewed corresponding-source'):
            atlas.collect_inputs(stage, {'licensedAtlases': self.receipt}, self.root)
        self.assertEqual(len(list((stage / 'vendor/PPSSPP/assets').iterdir())), 4)

    def test_older_personal_receipt_does_not_adopt_or_remove_resources(self):
        stage = self.stage()
        self.assertEqual(atlas.collect_inputs(stage, {}, self.root), {'inputs': [], 'exclusions': []})
        self.assertEqual(len(list((stage / 'vendor/PPSSPP/assets').iterdir())), 4)

    def test_source_generation_receipt_must_match_linked_component(self):
        stage = self.stage()
        with self.assertRaisesRegex(ValueError, 'receipt differs'):
            atlas.collect_inputs(stage, {'licensedAtlases': {}}, self.root)
        self.assertEqual(len(list((stage / 'vendor/PPSSPP/assets').iterdir())), 4)

    def test_quantizer_rejects_vectorization_corruption_and_clamps_dither(self):
        # At x0 the dither bias is -7; at x1 it is +1. All four channels
        # include endpoints and partial coverage, independent of font content.
        pixels = bytes((0, 255, 16, 128, 255, 0, 15, 127))
        expected = bytes((0, 255, 0, 119, 255, 0, 17, 136))
        self.assertEqual(atlas.verify_quantization(pixels, expected, 2, 1, 1), 2)
        bad = bytearray(expected); bad[3] = 255
        with self.assertRaisesRegex(ValueError, 'scalar reference'):
            atlas.verify_quantization(pixels, bad, 2, 1, 1)

    def test_git_free_source_requires_matching_revisions_and_actual_compiled_inputs(self):
        spec = importlib.util.spec_from_file_location('atlas_build', atlas.ROOT / 'ci/build-ppsspp-atlases.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        source = self.root / 'vendor/PPSSPP'
        tool = source / 'ext/native/tools/atlastool.cpp'; tool.parent.mkdir(parents=True)
        tool.write_text('reviewed rasterizer')
        unit = source / 'Common/Render/TextureAtlas.cpp'; unit.parent.mkdir(parents=True)
        unit.write_text('actual production parser')
        self.receipt.update(sourceRevisions={'ext/freetype': 'freetype-pin', 'ext/zstd': 'zstd-pin'},
                            upstreamToolSHA256=atlas.digest(tool),
                            compiledUpstreamSHA256={'PPSSPP/Common/Render/TextureAtlas.cpp': atlas.digest(unit)})
        (self.root / 'ci/psp-atlas-resources.json').write_text(json.dumps(self.receipt))
        revisions = {'vendor/PPSSPP': atlas.REVISION,
                     'vendor/PPSSPP/ext/freetype': 'freetype-pin', 'vendor/PPSSPP/ext/zstd': 'zstd-pin'}
        (self.root / 'SOURCE-REVISIONS.json').write_text(json.dumps(revisions))
        self.assertEqual(builder.source_revisions(source, self.root), self.receipt['sourceRevisions'])
        unit.write_text('changed parser')
        with self.assertRaisesRegex(ValueError, 'Archived host source differs'):
            builder.source_revisions(source, self.root)

    def test_git_free_source_does_not_accept_an_unrelated_directory(self):
        spec = importlib.util.spec_from_file_location('atlas_build', atlas.ROOT / 'ci/build-ppsspp-atlases.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        with self.assertRaisesRegex(ValueError, 'corresponding-source layout'):
            builder.source_revisions(self.root / 'other', self.root)


if __name__ == '__main__': unittest.main()
